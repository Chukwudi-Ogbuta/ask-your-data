#---------------------------------------SECTION 10: TESTING THE AI ON THE QUESTION BANK
# this script sends every question in question_bank_v1.csv to the AI (Groq),
# checks the SQL it writes is safe, runs it on the products table,
# and compares the result with the correct answer we wrote by hand.
# it can be stopped and restarted: questions already answered are skipped.
# everything it writes goes into one folder, eval_runs, so it can be deleted in one go.

suppressPackageStartupMessages({library(duckdb); library(httr2); library(jsonlite)})

# 10.1 settings
dir      <- file.path(Sys.getenv("HOME"), "mnt/ask-your-data")
run_dir  <- file.path(dir, "eval_runs")
dir.create(run_dir, showWarnings = FALSE)
model    <- Sys.getenv("EVAL_MODEL", "openai/gpt-oss-120b")
effort   <- Sys.getenv("EVAL_EFFORT", "low")          # how long the model thinks before answering
max_secs <- as.numeric(Sys.getenv("EVAL_MAX_SECS", "150")) # stop after this many seconds, rerun to continue
only_ids <- Sys.getenv("EVAL_IDS", "")                 # optional: test only these ids, e.g. "Q001,Q046"
tag      <- Sys.getenv("EVAL_TAG", "v1")                # round name, so each round keeps its own results file
out_file <- file.path(run_dir, paste0("results_", tag, "_", gsub("[^a-z0-9]", "_", model), "_", effort, ".csv"))

# the key is read from the file and never printed
key    <- gsub("[ \r\n]", "", readLines(file.path(dir, "groq_key.txt"), warn = FALSE)[1])
schema <- paste(readLines(file.path(dir, "schema_for_ai.md"), warn = FALSE, encoding = "UTF-8"), collapse = "\n")
con    <- dbConnect(duckdb(dbdir = file.path(Sys.getenv("HOME"), "work_vm.duckdb"), read_only = TRUE))

# real values of the text columns the AI filters on most, used by the value check (10.3b)
known <- list(
  food_group    = dbGetQuery(con, "SELECT DISTINCT food_group AS v FROM products WHERE food_group IS NOT NULL")$v,
  food_subgroup = dbGetQuery(con, "SELECT DISTINCT food_subgroup AS v FROM products WHERE food_subgroup IS NOT NULL")$v,
  brand         = unique(c(dbGetQuery(con, "SELECT DISTINCT brand_owner AS v FROM products")$v,
                           dbGetQuery(con, "SELECT DISTINCT brand_range AS v FROM products")$v)))
brand_top <- dbGetQuery(con, "SELECT brand_owner AS v FROM products GROUP BY 1 ORDER BY COUNT(*) DESC LIMIT 3000")$v

bank_file <- Sys.getenv("EVAL_BANK", "question_bank_v1.csv")   # which question bank to test
bank <- read.csv(file.path(dir, bank_file), stringsAsFactors = FALSE, encoding = "UTF-8", na.strings = character(0))
if (only_ids != "") bank <- bank[bank$id %in% strsplit(only_ids, ",")[[1]], ]
done <- if (file.exists(out_file)) read.csv(out_file, stringsAsFactors = FALSE)$id else character(0)
todo <- bank[!bank$id %in% done, ]

# 10.2 ask the AI one question and read its JSON answer
# the proxy address holds a long login name that R drops when reading it from the address,
# so we split it out and pass the name and password separately (only on the linked pc)
proxy_login <- function(req) {
  p <- Sys.getenv("HTTPS_PROXY")
  m <- regmatches(p, regexec("^https?://([^:]+):([^@]+)@([^:]+):([0-9]+)", p))[[1]]
  if (length(m) == 0) return(req)
  req_options(req, proxy = m[4], proxyport = as.integer(m[5]), proxyauth = 1L,
              proxyusername = URLdecode(m[2]), proxypassword = URLdecode(m[3]))
}
# extra: optional follow-up messages, used for the second chance when a query fails
ask_ai <- function(question, extra = list()) {
  req <- request("https://api.groq.com/openai/v1/chat/completions") |>
    req_auth_bearer_token(key) |>
    # the network proxy on this machine needs its login passed directly, in "basic" mode
    proxy_login() |>
    req_body_json(list(
      model = model, temperature = 0, reasoning_effort = effort,
      response_format = list(type = "json_object"),
      messages = c(list(list(role = "system", content = schema),
                        list(role = "user", content = question)), extra))) |>
    # when Groq says too many requests (429), wait the time it asks for and try again
    req_retry(max_tries = 6, is_transient = function(r) resp_status(r) %in% c(429, 500, 502, 503),
              after = function(r) { a <- resp_header(r, "retry-after"); if (is.null(a)) 20 else as.numeric(a) + 1 }) |>
    req_error(is_error = function(r) FALSE)
  resp <- req_perform(req)
  if (resp_status(resp) != 200) return(list(error = paste("http", resp_status(resp))))
  body <- resp_body_json(resp)
  ans  <- tryCatch(fromJSON(body$choices[[1]]$message$content), error = function(e) list(error = "reply was not valid json"))
  ans$tokens <- body$usage$total_tokens
  ans
}

# 10.3 safety check on the SQL the AI wrote
# only one SELECT (or WITH) statement, only the products table, no file or system functions
check_sql <- function(sql) {
  s <- tolower(sql)
  if (!grepl("^\\s*(select|with)\\b", s)) return("not a select")
  if (grepl(";\\s*\\S", s)) return("more than one statement")
  if (grepl("\\b(insert|update|delete|drop|create|alter|attach|detach|copy|pragma|install|load|export|import|call|set|truncate)\\b", s)) return("forbidden keyword")
  if (grepl("read_(csv|parquet|json|text|blob)|glob\\(|getenv|duckdb_|information_schema|sqlite_", s)) return("forbidden function")
  # EXTRACT(year FROM added_on) and TRIM(... FROM ...) use FROM without naming a table, so remove them first
  s <- gsub("\\b(extract|trim|substring)\\s*\\([^()]*\\)", "x", s)
  tables <- regmatches(s, gregexpr("\\b(from|join)\\s+([a-z_][a-z0-9_]*)", s))[[1]]
  tables <- unique(sub("^(from|join)\\s+", "", tables))
  # names defined in a WITH clause count as allowed tables
  ctes <- sub("\\s+as\\s*\\($", "", regmatches(s, gregexpr("([a-z_][a-z0-9_]*)\\s+as\\s*\\(", s))[[1]])
  bad  <- setdiff(tables, c("products", ctes, "unnest", "range"))
  if (length(bad) > 0) return(paste("other table:", paste(bad, collapse = " ")))
  "ok"
}

# 10.3b value check: every group, sub-group and brand named in the query must exist in the data
# returns "" when all is fine, otherwise a message telling the AI what is wrong and the closest real values
quoted <- function(x) gsub("'", "", regmatches(x, gregexpr("'[^']*'", x))[[1]])
check_values <- function(sql) {
  msgs <- character(0)
  for (col in c("food_subgroup", "food_group")) {
    hits <- regmatches(sql, gregexpr(paste0("\\b", col, "\\s*(=|<>|!=)\\s*'[^']*'|\\b", col, "\\s+(not\\s+)?in\\s*\\([^)]*\\)"), sql, ignore.case = TRUE))[[1]]
    for (v in unlist(lapply(hits, quoted))) {
      if (v %in% known[[col]]) next
      other <- setdiff(c("food_subgroup", "food_group"), col)
      hint <- if (v %in% known[[other]]) paste0("'", v, "' is a ", other, ", not a ", col, ".")
              else paste0("'", v, "' is not a ", col, ". Closest values: ",
                          paste0("'", known[[col]][order(stringdist::stringdist(tolower(v), tolower(known[[col]]), method = "jw"))[1:3]], "'", collapse = ", "), ".")
      msgs <- c(msgs, hint)
    }
  }
  hits <- regmatches(sql, gregexpr("\\bbrand_(owner|range)\\s*(=|i?like)\\s*'[^']*'", sql, ignore.case = TRUE))[[1]]
  for (h in hits) {
    v <- tolower(gsub("%", "", quoted(h)))
    found <- if (grepl("like", h, ignore.case = TRUE)) any(grepl(v, known$brand, fixed = TRUE)) else v %in% known$brand
    if (!found) {
      near <- brand_top[order(stringdist::stringdist(v, brand_top, method = "jw"))[1:3]]
      msgs <- c(msgs, paste0("No brand matches '", v, "' (maybe a typo). Closest brands: ", paste0("'", near, "'", collapse = ", "), "."))
    }
  }
  paste(unique(msgs), collapse = " ")
}

# 10.4 run a query, with a row cap so a bad query can't flood the result
run_sql <- function(sql) {
  sql <- sub(";\\s*$", "", sql)
  tryCatch(dbGetQuery(con, paste0("SELECT * FROM (", sql, ") AS t LIMIT 200")),
           error = function(e) conditionMessage(e))
}

# 10.5 compare the AI's result with the correct one
# rules: same number of rows; every text column of the correct answer must appear in the AI's
# result with the same values; when the correct answer is only numbers, each number column must
# appear too, allowing small rounding differences and percent vs share (x100).
same_numbers <- function(g, a) {
  g <- sort(as.numeric(g)); a <- sort(as.numeric(a))
  if (length(g) != length(a) || anyNA(a)) return(FALSE)
  # allowed gap: 0.05, or 0.5% of the value; when the correct answer was rounded to a whole number
  # (e.g. 45 kcal), an unrounded 45.3 is also fine
  tol <- pmax(0.051, 0.005 * abs(g), ifelse(g == round(g) & abs(g) >= 10, 0.5, 0))
  close <- function(x) all(abs(x - g) <= tol)
  close(a) || close(a / 100) || close(a * 100)
}
norm_text <- function(x) sort(tolower(trimws(as.character(x))))
compare <- function(gold, ai) {
  if (is.character(ai)) return("sql error")
  # the website shows a blank (unknown) group as a separate "unknown (not recorded)" line,
  # never as an answer, so blank-label rows are left out of the comparison
  txt <- !sapply(ai, function(x) is.numeric(x) || inherits(x, "integer64"))
  if (any(txt)) ai <- ai[stats::complete.cases(ai[txt]), , drop = FALSE]
  # a longer list is fine when its top rows are the correct answer (e.g. top 10 shown, top 1 asked)
  if (nrow(ai) > nrow(gold) && nrow(gold) <= 5) ai <- head(ai, nrow(gold))
  if (nrow(gold) != nrow(ai)) return("wrong row count")
  num_g <- sapply(gold, is.numeric); num_a <- sapply(ai, function(x) is.numeric(x) || inherits(x, "integer64"))
  if (any(!num_g)) {
    for (col in names(gold)[!num_g]) {
      if (!any(sapply(ai[!num_a], function(x) identical(norm_text(x), norm_text(gold[[col]]))))) return("wrong labels")
    }
    # labels are right; if the AI also gave numbers, they should match too,
    # otherwise it may have answered a different question, so we look at it by hand
    if (any(num_g) && any(num_a)) {
      for (col in names(gold)[num_g]) {
        if (!any(sapply(ai[num_a], function(x) same_numbers(gold[[col]], x)))) return("check")
      }
    }
    return("pass")
  }
  for (col in names(gold)) {
    if (!any(sapply(ai[num_a], function(x) same_numbers(gold[[col]], x)))) return("wrong number")
  }
  "pass"
}
show <- function(df) if (is.character(df)) df else paste(apply(head(df, 5), 1, function(x) paste(trimws(x), collapse = " | ")), collapse = " ; ")

# 10.5b rescore mode: when the checker changes, re-check saved results without calling the AI again
# it reruns the SQL the AI already wrote, so it costs no tokens
if (Sys.getenv("EVAL_RESCORE") != "") {
  res <- read.csv(out_file, stringsAsFactors = FALSE, na.strings = character(0))
  for (i in seq_len(nrow(res))) {
    q <- bank[bank$id == res$id[i], ]
    if (nrow(q) == 0 || q$expected_status != "ok" || res$ai_status[i] != "ok" || !nzchar(res$ai_sql[i])) next
    if (check_sql(res$ai_sql[i]) != "ok") next
    a <- run_sql(res$ai_sql[i]); v <- compare(run_sql(q$gold_sql), a)
    if (v != "pass" && nzchar(q$gold_sql_alt) && compare(run_sql(q$gold_sql_alt), a) == "pass") v <- "pass"
    res$verdict[i] <- v
  }
  write.csv(res, out_file, row.names = FALSE, fileEncoding = "UTF-8")
  cat("rescored", nrow(res), "| passed", sum(res$verdict == "pass"), sprintf("(%.0f%%)\n", 100 * mean(res$verdict == "pass")))
  print(res[res$verdict != "pass", c("id", "verdict", "question")], row.names = FALSE)
  quit(save = "no")
}

# 10.6 main loop: one question at a time, results saved after each one
start <- Sys.time()
for (i in seq_len(nrow(todo))) {
  if (as.numeric(difftime(Sys.time(), start, units = "secs")) > max_secs) break
  q   <- todo[i, ]
  ans <- ask_ai(q$question)
  status <- if (!is.null(ans$error)) "error" else as.character(ans$status)
  sql    <- if (is.null(ans$sql)) "" else as.character(ans$sql)
  safety <- if (nzchar(sql)) check_sql(sql) else ""
  # second chance: if the query is safe but crashes, send the error back once and let the AI fix it
  second_chance <- FALSE
  if (is.null(ans$error) && status == "ok" && safety == "ok") {
    first <- run_sql(sql)
    # two reasons for a second chance: the query crashed, or its top answer is an unknown (blank) value
    problem <- check_values(sql)
    if (nzchar(problem)) {
      problem <- paste("Some values in that query do not exist in the data.", problem)
    } else if (is.character(first)) {
      problem <- paste("That query failed in DuckDB with this error:", substr(first, 1, 400))
    } else if (nrow(first) > 0) {
      txt <- !sapply(first, function(x) is.numeric(x) || inherits(x, "integer64"))
      if (any(txt) && anyNA(first[1, txt]))
        problem <- "The top row of that result is an unknown (NULL) value. Leave out NULL values with WHERE <column> IS NOT NULL."
    }
    if (nzchar(problem)) {
      fix <- ask_ai(q$question, list(
        list(role = "assistant", content = as.character(toJSON(ans[c("status", "sql", "assumptions", "clarification")], auto_unbox = TRUE))),
        list(role = "user", content = paste(problem, "Correct the query. Return the same JSON format only."))))
      if (is.null(fix$error)) {
        fix$tokens <- sum(ans$tokens, fix$tokens, na.rm = TRUE)
        ans <- fix; second_chance <- TRUE
        status <- as.character(ans$status)
        sql    <- if (is.null(ans$sql)) "" else as.character(ans$sql)
        safety <- if (nzchar(sql)) check_sql(sql) else ""
      }
    }
  }
  verdict <- ""; ai_res <- ""; gold_res <- ""
  if (!is.null(ans$error)) {
    verdict <- paste("ai error:", ans$error)
  } else if (!grepl("^ok$", q$expected_status)) {
    # for unclear, out-of-scope and unsafe questions, the right status is the whole test
    # some questions accept two statuses, written as "a|b"
    verdict <- if (status %in% strsplit(q$expected_status, "|", fixed = TRUE)[[1]]) "pass" else "wrong status"
  } else if (status != "ok") {
    verdict <- "wrong status"
  } else if (safety != "ok") {
    verdict <- paste("unsafe sql:", safety)
  } else {
    a <- run_sql(sql); g <- run_sql(q$gold_sql)
    verdict <- compare(g, a)
    # if a second correct reading exists, accept it too
    if (verdict != "pass" && nzchar(q$gold_sql_alt)) {
      g2 <- run_sql(q$gold_sql_alt)
      if (compare(g2, a) == "pass") { verdict <- "pass"; g <- g2 }
    }
    ai_res <- show(a); gold_res <- show(g)
  }
  row <- data.frame(id = q$id, type = q$type, lang = q$lang, question = q$question,
                    expected_status = q$expected_status, ai_status = status, verdict = verdict,
                    ai_sql = sql, ai_result = ai_res, gold_result = gold_res,
                    assumptions = paste(as.character(ans$assumptions), collapse = " "),
                    clarification = paste(as.character(ans$clarification), collapse = " "),
                    second_chance = second_chance,
                    tokens = if (is.null(ans$tokens)) NA else ans$tokens)
  write.table(row, out_file, sep = ",", row.names = FALSE, col.names = !file.exists(out_file),
              append = file.exists(out_file), fileEncoding = "UTF-8", qmethod = "double")
  cat(q$id, verdict, "\n")
}

# 10.7 scorecard so far
res <- read.csv(out_file, stringsAsFactors = FALSE)
cat("\nanswered", nrow(res), "of", nrow(bank), "| passed", sum(res$verdict == "pass"),
    sprintf("(%.0f%%)", 100 * mean(res$verdict == "pass")), "| tokens used", sum(res$tokens, na.rm = TRUE), "\n")
print(aggregate(cbind(passed = verdict == "pass", total = 1) ~ type, data = res, FUN = sum))
dbDisconnect(con, shutdown = TRUE)
