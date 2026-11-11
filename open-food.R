#----------------------------------------------------------------------------------------------------------
# PROJECT:  Ask Your Data: AI text-to-SQL tool on Open Food Facts
# SCRIPT:   01_explore.R: first look at the raw file, save French products locally, check and clean data
# AUTHOR:   Chukwudi Samuel Ogbuta
# DATA:     Open Food Facts full export (ODbL licence), en.openfoodfacts.org.products.csv.gz
#----------------------------------------------------------------------------------------------------------

#---------------------------------------SECTION 1: LOAD PACKAGES
library(duckdb)    # small database engine that runs inside R
library(dplyr)     # data manipulation
library(stringr)   # text helpers such as str_squish
library(stringi)   # accent removal
library(tidyr)     # for separate_rows (move this line to Section 1 with the others)
library(stringdist)   # text similarity such as Jaro-Winkler

#---------------------------------------SECTION 2: CONNECT AND POINT TO THE FILE
dir <- "C:/Users/Ogbuta/Documents/ask-your-data"                  # project folder where everything stays
con <- dbConnect(duckdb(dbdir = file.path(dir, "work.duckdb")))   # local database file kept between sessions
f   <- file.path(dir, "en.openfoodfacts.org.products.csv.gz")     # raw export kept zipped, about 9 GB unzipped

# how DuckDB reads the raw file
#   delim='\t'          columns are separated by tabs
#   quote=''            quote marks are treated as normal text
#   header=true         first line holds the column names
#   all_varchar=true    every column is read as text so odd values cannot break the import
#   ignore_errors=true  badly formed lines are skipped instead of stopping the import
src <- sprintf("read_csv('%s', delim='\\t', quote='', header=true, all_varchar=true, ignore_errors=true)", f)

#---------------------------------------SECTION 3: FIRST LOOK AT THE RAW FILE (WORLD)

# 3.1 column names and number of columns
cols <- dbGetQuery(con, paste("DESCRIBE SELECT * FROM", src))
nrow(cols)                 # number of columns, result 211
print(cols$column_name)    # names of all columns

# 3.2 number of rows worldwide
#     reads the whole file once; counts rows, not unique products (duplicates checked in 5.6)
dbGetQuery(con, paste("SELECT COUNT(*) AS n_rows FROM", src))   # result 4,904,675

# 3.3 five example products with a few key columns
dbGetQuery(con, paste("SELECT code, product_name, brands, countries_en, nutriscore_grade FROM", src, "LIMIT 5"))

#---------------------------------------SECTION 4: SAVE FRENCH PRODUCTS LOCALLY (RUN ONCE)

# 4.1 keep every column, only products sold in France
#     countries_tags can list several countries, so a product is kept if en:france appears anywhere in it
dbExecute(con, paste("CREATE OR REPLACE TABLE fr AS SELECT * FROM", src,
                     "WHERE countries_tags LIKE '%en:france%'"))

# 4.2 confirm how many French products were saved
dbGetQuery(con, "SELECT COUNT(*) AS n_france FROM fr")   # result 1,296,304, about 26% of the world file

#---------------------------------------SECTION 5: DATA QUALITY CHECKS ON THE LOCAL FRENCH COPY

# 5.1 view 4 French products that have a name, turned sideways with one line per column
rows <- dbGetQuery(con, "SELECT * FROM fr WHERE product_name IS NOT NULL LIMIT 4")
view <- t(rows)                              # swap rows and columns
colnames(view) <- paste0("product_", 1:4)    # name the 4 product columns
View(view)

# 5.2 percentage of missing or blank values in every column, least missing first
#     percentages are rounded to 1 decimal, so a few missing values can still show as 0.0
all_cols <- cols$column_name
miss_sql <- paste0("ROUND(100 * AVG(CASE WHEN \"", all_cols, "\" IS NULL OR trim(\"", all_cols,
                   "\") = '' THEN 1 ELSE 0 END), 1) AS \"", all_cols, "\"", collapse = ", ")
miss <- dbGetQuery(con, paste("SELECT", miss_sql, "FROM fr"))
miss_long <- data.frame(column = names(miss), pct_missing = as.numeric(miss[1, ]))   # one row per column
miss_long <- miss_long[order(miss_long$pct_missing), ]                                # least missing first
View(miss_long)

# a brand counts as missing if it is NULL or blank, used in 5.3 and 5.4
brand_missing <- "CASE WHEN brands IS NULL OR trim(brands) = '' THEN 1 ELSE 0 END"

# 5.3 missing brands by creator, for the 15 accounts that added the most French products
#     result: retailers are near 0% missing, scanning apps (kiliweb, about 997,000 products) are much higher
by_creator <- dbGetQuery(con, paste0(
  "SELECT creator, COUNT(*) AS n_products, ",
  "ROUND(100 * AVG(", brand_missing, "), 1) AS pct_brand_missing ",
  "FROM fr GROUP BY creator ORDER BY n_products DESC LIMIT 15"))
View(by_creator)

# 5.4 missing brands by completeness band
#     completeness is a 0 to 1 score stored as text, so it is converted to a number first
#     result: missing brands sit almost entirely in products with completeness below 0.5
by_complete <- dbGetQuery(con, paste0(
  "SELECT ROUND(FLOOR(TRY_CAST(completeness AS DOUBLE) * 10) / 10, 1) AS completeness_band, ",
  "COUNT(*) AS n_products, ",
  "ROUND(100 * AVG(", brand_missing, "), 1) AS pct_brand_missing ",
  "FROM fr GROUP BY completeness_band ORDER BY completeness_band"))
View(by_complete)

# 5.5 the 515 products with no completeness value, look at 20 of them
#     result: completeness is truly empty for these products, decision: drop them in 6.1
bad <- dbGetQuery(con, "SELECT code, product_name, brands, completeness, creator
                        FROM fr
                        WHERE TRY_CAST(completeness AS DOUBLE) IS NULL
                        LIMIT 20")
View(bad)

# 5.6 duplicates check, each barcode should appear only once
#     result: 1,296,304 rows vs 1,296,281 unique barcodes, so 23 barcodes appear twice
dbGetQuery(con, "SELECT COUNT(*) AS n_rows, COUNT(DISTINCT code) AS n_unique_codes FROM fr")

# list the barcodes that appear more than once
dups <- dbGetQuery(con, "SELECT code, COUNT(*) AS times FROM fr GROUP BY code HAVING COUNT(*) > 1 ORDER BY times DESC")
View(dups)

# 5.7 for each repeated barcode, are its 2 rows identical in all 211 columns
#     in DuckDB, writing the table name fr inside the query means the whole row
same <- dbGetQuery(con, "SELECT code, COUNT(*) AS times, COUNT(DISTINCT fr) AS distinct_versions
                         FROM fr
                         WHERE code IN (SELECT code FROM fr GROUP BY code HAVING COUNT(*) > 1)
                         GROUP BY code")
View(same)

# look at one repeated barcode side by side, one line per column
pair <- dbGetQuery(con, "SELECT * FROM fr WHERE code = '3760325483199'")
View(t(pair))

# 5.8 products with completeness above 1, which exact values appear and how often
#     result: 10,543 products between 1.05 and 1.1, in equal steps of 0.0125, decision: cap at 1 in 6.6
over1 <- dbGetQuery(con, "SELECT completeness, COUNT(*) AS n_products
                          FROM fr
                          WHERE TRY_CAST(completeness AS DOUBLE) > 1
                          GROUP BY completeness
                          ORDER BY n_products DESC")
View(over1)

#---------------------------------------SECTION 6: CLEANING (BUILDS FR_CLEAN, FR STAYS UNTOUCHED)

# 6.1 drop the 515 products with no completeness score
dbExecute(con, "CREATE OR REPLACE TABLE fr_clean AS
                SELECT * FROM fr
                WHERE TRY_CAST(completeness AS DOUBLE) IS NOT NULL")
dbGetQuery(con, "SELECT COUNT(*) AS n_after_6_1 FROM fr_clean")   # expect 1,296,304 minus 515 = 1,295,789

# 6.2 duplicates: for each barcode keep only the most recently modified row
#     ROW_NUMBER numbers the rows of each barcode from newest (1) to oldest, and we keep number 1
dbExecute(con, "CREATE OR REPLACE TABLE fr_clean AS
                SELECT * EXCLUDE (rn) FROM (
                  SELECT *, ROW_NUMBER() OVER (PARTITION BY code
                         ORDER BY TRY_CAST(last_modified_t AS BIGINT) DESC) AS rn
                  FROM fr_clean)
                WHERE rn = 1")
dbGetQuery(con, "SELECT COUNT(*) AS n_rows, COUNT(DISTINCT code) AS n_unique FROM fr_clean")   # both numbers must match, result 1,295,766

# 6.3 drop columns that are completely empty
#     exact counts with no rounding, a column is dropped only if not one product has a value
all_cols <- dbGetQuery(con, "DESCRIBE fr_clean")$column_name
fill_sql <- paste0("COUNT(CASE WHEN trim(\"", all_cols, "\") <> '' THEN 1 END) AS \"", all_cols, "\"", collapse = ", ")
filled   <- dbGetQuery(con, paste("SELECT", fill_sql, "FROM fr_clean"))
empty_cols <- names(filled)[as.numeric(filled[1, ]) == 0]
length(empty_cols)   # how many columns are completely empty, result 6
print(empty_cols)    # their names

dbExecute(con, paste0("CREATE OR REPLACE TABLE fr_clean AS SELECT * EXCLUDE (",
                      paste0('"', empty_cols, '"', collapse = ", "), ") FROM fr_clean"))

# 6.4 review table: every remaining column with its exact number and percentage of missing values
left_cols <- dbGetQuery(con, "DESCRIBE fr_clean")$column_name
n_total   <- dbGetQuery(con, "SELECT COUNT(*) AS n FROM fr_clean")$n
review <- data.frame(column    = left_cols,
                     n_filled  = as.numeric(filled[1, left_cols]))
review$n_missing   <- n_total - review$n_filled
review$pct_missing <- round(100 * review$n_missing / n_total, 2)
review <- review[order(review$pct_missing), ]   # least missing first
rownames(review) <- NULL                        # renumber rows 1, 2, 3 after sorting
View(review)

# 6.5 keep only the 33 columns we chose
#     column names that contain a hyphen need double quotes in SQL
keep <- c("code","product_name","brands","quantity",
          "main_category_en","categories_en","pnns_groups_1","pnns_groups_2",
          "nutriscore_grade","nutriscore_score","nova_group","additives_n","additives_en","allergens_en",
          "energy-kcal_100g","fat_100g","saturated-fat_100g","carbohydrates_100g","sugars_100g",
          "fiber_100g","proteins_100g","salt_100g","alcohol_100g",
          "labels_en","environmental_score_grade","packaging_en","countries_en",
          "completeness","creator","data_quality_errors_tags","unique_scans_n",
          "created_datetime","last_modified_datetime")
dbExecute(con, paste0("CREATE OR REPLACE TABLE fr_clean AS SELECT ",
                      paste0('"', keep, '"', collapse = ", "), " FROM fr_clean"))
length(dbGetQuery(con, "DESCRIBE fr_clean")$column_name)   # expect 33

# 6.6 cap completeness at 1
#     the score should run from 0 to 1, but 10,543 products go up to 1.1 (see 5.8), so anything above 1 becomes 1
dbExecute(con, "UPDATE fr_clean
                SET completeness = '1'
                WHERE TRY_CAST(completeness AS DOUBLE) > 1")
dbGetQuery(con, "SELECT MAX(TRY_CAST(completeness AS DOUBLE)) AS max_completeness FROM fr_clean")   # expect 1

# 6.7 keep only products with completeness of 0.5 or more
#     decision from 5.4: about 5% of brands missing above 0.5, about 70% below
dbExecute(con, "CREATE OR REPLACE TABLE fr_clean AS
                SELECT * FROM fr_clean
                WHERE TRY_CAST(completeness AS DOUBLE) >= 0.5")
dbGetQuery(con, "SELECT COUNT(*) AS n_after_cut FROM fr_clean")   # expect about 431,000

# 6.8 drop products with no brand name, because brand questions are central to the tool
dbExecute(con, "DELETE FROM fr_clean WHERE brands IS NULL OR trim(brands) = ''")
dbGetQuery(con, "SELECT COUNT(*) AS n_after_brand_drop FROM fr_clean")   # expect about 410,000

#---------------------------------------SECTION 7: COLUMN-BY-COLUMN REVIEW (ON FR_CLEAN)

# 7.0 helper: for any column, show the number of different values, the number of empty values,
#     and the 30 most common values with their counts
col_check <- function(column) {
  q <- sprintf('"%s"', column)   # wrap the name in quotes, needed for names with a hyphen
  print(dbGetQuery(con, sprintf(
    "SELECT COUNT(DISTINCT %s) AS n_distinct_values,
            COUNT(*) - COUNT(%s) AS n_empty
     FROM fr_clean", q, q)))
  top <- dbGetQuery(con, sprintf(
    "SELECT %s AS value, COUNT(*) AS n_products
     FROM fr_clean GROUP BY %s ORDER BY n_products DESC LIMIT 30", q, q))
  View(top, title = column)   # opens the top values in a viewer tab named after the column
}

# 7.1 code: barcodes should be digits only, with a standard length
#     result: all digits only; 98.8% have 8 or 13 digits, about 4,800 have non-standard lengths
dbGetQuery(con, "SELECT LENGTH(code) AS n_digits,
                        COUNT(*) AS n_products,
                        SUM(CASE WHEN regexp_matches(code, '^[0-9]+$') THEN 0 ELSE 1 END) AS n_not_digits_only
                 FROM fr_clean
                 GROUP BY n_digits ORDER BY n_products DESC")

# 7.1b code: keep only official barcode lengths 8 (EAN-8), 12 (UPC-A), 13 (EAN-13) and 14 (GTIN-14)
#      drops about 4,800 products (1.2%) with non-standard codes, likely shop internal or mistyped
dbExecute(con, "DELETE FROM fr_clean WHERE LENGTH(code) NOT IN (8, 12, 13, 14)")
dbGetQuery(con, "SELECT COUNT(*) AS n_after_code_check FROM fr_clean")   # expect about 405,015

# 7.2 product_name: number of different names, number empty, and the 30 most common
#     result: names are free text and not standardised; the barcode, not the name, identifies a product
col_check("product_name")

# 7.2b product_name: drop products with no name, about 3,241 products, under 1%
dbExecute(con, "DELETE FROM fr_clean WHERE product_name IS NULL OR trim(product_name) = ''")
dbGetQuery(con, "SELECT COUNT(*) AS n_after_name_drop FROM fr_clean")

# 7.3 brands: number of different brands and the 30 most common
#     result: 83,854 different values, free typing and several brands in one cell
col_check("brands")

# 7.3b brands: move to R and normalise
brands_df <- dbGetQuery(con, "SELECT code, brands FROM fr_clean")   # barcode and brand, one row per product

# accents become plain letters, everything lowercase, ends trimmed and inner spaces collapsed
brands_df <- brands_df %>%
  mutate(brands_norm = brands %>%
           stri_trans_general("Latin-ASCII") %>%   # accented letters become plain letters
           str_to_lower() %>%                      # everything lowercase
           str_squish())                           # remove extra spaces

# how much normalising reduced the number of unique values
n_distinct(brands_df$brands)        # before, result 83,854
n_distinct(brands_df$brands_norm)   # after, result 65,557

# 7.3c brands: split cells that list several brands into one row per brand
#      for example "u, u bio" becomes two rows, "u" and "u bio"
sum(str_detect(brands_df$brands_norm, ","))   # number of products that list more than one brand

brands_long <- brands_df %>%
  separate_rows(brands_norm, sep = ",") %>%     # one row per brand in the cell
  mutate(brand = str_squish(brands_norm)) %>%   # remove the space left after each comma
  filter(brand != "") %>%                       # drop empty pieces left by trailing commas
  select(code, brand)

nrow(brands_long)               # total product and brand pairs
n_distinct(brands_long$brand)   # unique individual brands after splitting

# 7.3d brands: how many products each individual brand has, grouped into size bands
brand_sizes <- brands_long %>%
  count(brand, name = "n_products") %>%                                   # products per brand
  mutate(size_band = cut(n_products, breaks = c(0, 1, 5, 20, 100, Inf),
                         labels = c("1", "2-5", "6-20", "21-100", "100+")))

brand_sizes %>% count(size_band, name = "n_brands")   # number of brands in each size band

# share of all product and brand pairs covered by the 2,000 biggest brands
top2000 <- brand_sizes %>% arrange(desc(n_products)) %>% slice(1:2000)
round(100 * sum(top2000$n_products) / sum(brand_sizes$n_products), 1)

# 7.3e brands: find likely spelling mistakes with Jaro-Winkler, list them only, merge nothing yet
#      big brands are the 2,000 with the most products, small brands have 5 products or fewer
#      names shorter than 4 letters are skipped because short names give false matches
anchors <- brand_sizes %>% arrange(desc(n_products)) %>% slice(1:2000)
small   <- brand_sizes %>% filter(n_products <= 5, nchar(brand) >= 4, !brand %in% anchors$brand)

# for each small brand, find the closest big brand within a Jaro-Winkler distance of 0.05
# a distance of 0.05 means a similarity of 0.95 or more, and no match within that gives NA
idx <- amatch(small$brand, anchors$brand, method = "jw", p = 0.1, maxDist = 0.05)

candidates <- small %>%
  mutate(match_brand    = anchors$brand[idx],         # closest big brand
         match_products = anchors$n_products[idx],    # how many products the big brand has
         similarity     = round(1 - stringdist(brand, match_brand, method = "jw", p = 0.1), 3)) %>%
  filter(!is.na(match_brand)) %>%                     # keep only small brands that found a match
  arrange(desc(n_products), similarity)

nrow(candidates)   # how many small brands look like a misspelt big brand
View(candidates)   # check them by eye before anything is merged

# save the candidate matches to the project folder so they can be shared
write.csv(candidates, file.path(dir, "candidates_7_3e.csv"), row.names = FALSE)

# 7.3f brands: remove punctuation differences, then re-run the matching with a stricter threshold
#      hyphens become spaces, apostrophes and dots are removed, and & always gets a space on each side
brands_long <- brands_long %>%
  mutate(brand = brand %>%
           str_replace_all("-", " ") %>%       # kusmi-tea becomes kusmi tea
           str_replace_all("['.]", "") %>%     # cote d'or becomes cote dor
           str_replace_all("&", " & ") %>%     # qualite&prix becomes qualite & prix
           str_squish())                       # tidy the spaces created above

n_distinct(brands_long$brand)   # unique brands after this rule, was 57,850

# rebuild the brand sizes, the big brands and the small brands with the new names
brand_sizes <- brands_long %>% count(brand, name = "n_products")
anchors <- brand_sizes %>% arrange(desc(n_products)) %>% slice(1:2000)
small   <- brand_sizes %>% filter(n_products <= 5, nchar(brand) >= 4, !brand %in% anchors$brand)

# match again, accepting only a similarity of 0.97 or more (a distance of 0.03 or less)
idx <- amatch(small$brand, anchors$brand, method = "jw", p = 0.1, maxDist = 0.03)

candidates <- small %>%
  mutate(match_brand    = anchors$brand[idx],
         match_products = anchors$n_products[idx],
         similarity     = round(1 - stringdist(brand, match_brand, method = "jw", p = 0.1), 3)) %>%
  filter(!is.na(match_brand)) %>%
  arrange(similarity)   # lowest scores first, where the traps are most likely

nrow(candidates)   # number of suggested fixes
write.csv(candidates, file.path(dir, "candidates_7_3f.csv"), row.names = FALSE)   # save to share

# 7.3g brands: apply the spelling fixes, except the 15 pairs that are different names
exclude <- c("natural","naturel","natures","marine","marino","maximus","farmers",
             "la laiterie","la boulangerie","la bergere","fromagerie bernard",
             "presidente","continent","les 3 marmottes","moulin des mondes","tropic")

fixes <- candidates %>%
  filter(!brand %in% exclude) %>%   # keep only the genuine typos
  select(brand, match_brand)        # misspelt name and its correct big brand

nrow(fixes)   # number of fixes applied, about 585

write.csv(fixes, file.path(dir, "brand_fixes_7_3g.csv"), row.names = FALSE)   # saved as part of the cleaning log

# replace each misspelt name with its correct big brand, leave all other names as they are
brands_long <- brands_long %>%
  left_join(fixes, by = "brand") %>%
  mutate(brand = coalesce(match_brand, brand)) %>%   # use the fix when there is one
  select(code, brand)

n_distinct(brands_long$brand)   # unique brands after the fixes

# 7.3h brands: look at the corrected list, every brand with its number of products, biggest first
brand_sizes <- brands_long %>%
  count(brand, name = "n_products") %>%
  arrange(desc(n_products))
View(brand_sizes)   # use the search box to check names, for example type carrefour or leclerc

# spot check: a few misspelt names that should no longer exist, expect 0
sum(brands_long$brand %in% c("carrfour", "nespreso", "leadder price", "bonduell"))

# 7.3i brands: which words appear in the most different brand names
#      small French linking words are removed because they appear everywhere and mean nothing
stop_words <- c("de","la","le","les","du","des","et","&","d","l","a","en","au","aux")

brand_words <- brand_sizes %>%
  mutate(word = str_split(brand, " ")) %>%   # split each brand name into its words
  unnest(word) %>%                           # one row per brand name per word
  filter(!word %in% stop_words, nchar(word) >= 2) %>%
  group_by(word) %>%
  summarise(n_brand_names = n_distinct(brand),     # how many different brand names contain the word
            n_products    = sum(n_products)) %>%   # how many products those names cover
  arrange(desc(n_brand_names))
View(brand_words)

# 7.3j brands: which pairs of brands are listed together on the same product, and how often
brand_pairs <- brands_long %>%
  distinct(code, brand) %>%
  inner_join(brands_long %>% distinct(code, brand), by = "code",
             relationship = "many-to-many") %>%      # every pair of brands on the same product
  filter(brand.x < brand.y) %>%                      # keep each pair once and drop a brand paired with itself
  count(brand.x, brand.y, name = "n_products_together") %>%
  arrange(desc(n_products_together))
View(brand_pairs)

# 7.3k export only the part worth reviewing: frequent pairs and the top 100 words
top_pairs <- brand_pairs %>% filter(n_products_together >= 20)
nrow(top_pairs)   # how many pairs to review
write.csv(top_pairs, file.path(dir, "brand_pairs_top_7_3k.csv"), row.names = FALSE)

top_words <- brand_words %>% slice(1:100)
write.csv(top_words, file.path(dir, "brand_words_top_7_3k.csv"), row.names = FALSE)

# 7.3l brands: strip legal endings, then find each brand's owner from shared words at the start or end

# part 1: remove brackets and legal company endings such as sas, sarl, gmbh, co kg
legal_endings <- "\\s+(&\\s+)?(co\\s+kg|gmbh|sas|sarl|sa|inc|ltd|gaec|spa|sl|srl|ag|bv|nv|plc|llc|kg)$"
brands_long <- brands_long %>%
  mutate(brand = brand %>%
           str_replace_all("[()]", " ") %>%       # milbona (lidl) becomes milbona lidl
           str_squish() %>%
           str_replace(legal_endings, "") %>%     # alnatura gmbh becomes alnatura
           str_squish())

brand_sizes <- brands_long %>% count(brand, name = "n_products")   # recount with the new names
n_distinct(brands_long$brand)                                       # unique brands after part 1

# part 2: possible owners are real brands with 20 or more products that are not generic words
generic <- c("bio","maison","saint","st","san","la","le","les","nature","france","ferme","domaine","chateau",
             "food","foods","the","gourmet","selection","saveurs","delices","organic","natural","grand",
             "petit","bon","royal","belle","fresh","green","good","gold","pere","casa","chef","terre","miel",
             "pasta","tea","cafe","lait","frais","fruits","fruit","traiteur","brand","pain","moulin",
             "fromagerie","biscuiterie","brasserie","co","company","di","del","el","il","nos","sans marque")
owners_pool <- brand_sizes %>% filter(n_products >= 20, !brand %in% generic)

# every way to cut a name into a start part or an end part made of whole words
# for example carrefour bio france gives carrefour, carrefour bio, bio france and france
make_parts <- function(words) {
  n <- length(words)
  starts <- sapply(1:(n - 1), function(k) paste(words[1:k], collapse = " "))
  ends   <- sapply(2:n,       function(k) paste(words[k:n], collapse = " "))
  c(starts, ends)
}

multi_word <- brand_sizes %>%
  mutate(words = str_split(brand, " ")) %>%
  filter(lengths(words) >= 2)                 # only names with 2 or more words can contain an owner

owner_map <- tibble(brand = multi_word$brand, part = lapply(multi_word$words, make_parts)) %>%
  unnest(part) %>%
  inner_join(owners_pool %>% select(part = brand), by = "part") %>%   # keep parts that are real owners
  group_by(brand) %>%
  slice_min(nchar(part), n = 1, with_ties = FALSE) %>%                # shortest owner is the parent
  ungroup() %>%
  rename(owner = part)

nrow(owner_map)   # number of brand names that found an owner

# check: owners with the most ranges, and every range found for each
owner_check <- owner_map %>%
  group_by(owner) %>%
  summarise(n_ranges = n(), ranges = paste(head(brand, 15), collapse = " | ")) %>%
  arrange(desc(n_ranges))
View(owner_check)
write.csv(owner_check, file.path(dir, "owner_check_7_3l.csv"), row.names = FALSE)   # to share


# 7.3m brands: fix the legal ending bug, exclude generic words from owners, and find owners again

# part 1: remove spanish and other legal endings written with spaces, such as s a u, s a, s l
brands_long <- brands_long %>%
  mutate(brand = brand %>%
           str_replace("\\s+s\\s+a(\\s+u)?$", "") %>%   # campofrio food group s a u becomes campofrio food group
           str_replace("\\s+s\\s+l$", "") %>%
           str_squish())
brand_sizes <- brands_long %>% count(brand, name = "n_products")   # recount with the new names

# part 2: common words and first names that are also small brands, so they must never be owners
generic_extra <- c("delice","michel","sun","terroir","terroirs","kitchen","natura","societe","garden","life",
                   "sapori","simply","marie","mix","real","eco","comte","veggie","classic","halal","sante",
                   "sans","extra","kids","midi","master","lion","malo","prince","you","mama","roger","cook",
                   "cucina","duc","noel","simon","star","bel","la vie","tasty","arnaud","atlantic","elephant",
                   "robert","bien","gilbert","papillon","prima","river","vichy","cereal","tiger","viva",
                   "belgian","destination","gallo","imperial","tresor","bouquet","burger","costa","crunch",
                   "excellence","le marche","jacobs","lotus","coop")
generic <- unique(c(generic, generic_extra))
owners_pool <- brand_sizes %>% filter(n_products >= 20, !brand %in% generic)

# part 3: same owner search as 7.3l, on the updated names
multi_word <- brand_sizes %>%
  mutate(words = str_split(brand, " ")) %>%
  filter(lengths(words) >= 2)

owner_map <- tibble(brand = multi_word$brand, part = lapply(multi_word$words, make_parts)) %>%
  unnest(part) %>%
  inner_join(owners_pool %>% select(part = brand), by = "part") %>%
  group_by(brand) %>%
  slice_min(nchar(part), n = 1, with_ties = FALSE) %>%
  ungroup() %>%
  rename(owner = part)

nrow(owner_map)   # number of brand names that found an owner, was higher before the exclusions

owner_check <- owner_map %>%
  group_by(owner) %>%
  summarise(n_ranges = n(), ranges = paste(head(brand, 15), collapse = " | ")) %>%
  arrange(desc(n_ranges))
write.csv(owner_check, file.path(dir, "owner_check_7_3m.csv"), row.names = FALSE)   # to share

# 7.3n brands: final owner and range for every product, written back to fr_clean

# part 1: more common words and surnames that must not be owners, then find owners again
generic <- unique(c(generic, "marius","muller","roland","felix","germain","mercier","perrier","vrai","soy",
                    "fitness","elite","eden","delta","bear","oasis","mission","farmer","sultan","la truffe",
                    "sans sucres ajoutes","broceliande","manosque","mont blanc","saint jean","st michel","lor"))
owners_pool <- brand_sizes %>% filter(n_products >= 20, !brand %in% generic)

owner_map <- tibble(brand = multi_word$brand, part = lapply(multi_word$words, make_parts)) %>%
  unnest(part) %>%
  inner_join(owners_pool %>% select(part = brand), by = "part") %>%
  group_by(brand) %>%
  slice_min(nchar(part), n = 1, with_ties = FALSE) %>%
  ungroup() %>%
  rename(owner = part)

# part 2: owners written under two names are merged into one
alias <- tribble(
  ~from,                                            ~to,
  "eleclerc",                                       "leclerc",
  "marque repere",                                  "leclerc",
  "scamark filiale e leclerc",                      "leclerc",
  "groupe carrefour",                               "carrefour",
  "cmi carrefour marchandises internationales",     "carrefour",
  "dlp distribution leader price",                  "leader price",
  "groupe casino",                                  "casino",
  "groupe auchan",                                  "auchan",
  "super u",                                        "u",
  "systeme u",                                      "u")

lookup <- brand_sizes %>%
  select(brand) %>%
  left_join(owner_map, by = "brand") %>%
  mutate(owner = coalesce(owner, brand)) %>%           # no owner found means the brand is its own owner
  left_join(alias, by = c("owner" = "from")) %>%
  mutate(owner = coalesce(to, owner)) %>%              # apply the merged owner names
  select(brand, owner)

# part 3: one owner and one range per product
#   owner: when a product lists several owners, the biggest one wins (most products in the data)
#   range: the most specific name under that owner; if there is none, the range is the owner itself
prod <- brands_long %>%
  distinct(code, brand) %>%
  left_join(lookup, by = "brand")

owner_size <- prod %>% distinct(code, owner) %>% count(owner, name = "owner_products")

prod <- prod %>%
  left_join(owner_size, by = "owner") %>%
  mutate(is_range = !(brand == owner | brand %in% alias$from))   # a pure owner name is not a range

brand_final <- prod %>%
  group_by(code) %>%
  summarise(
    brand_owner = owner[which.max(owner_products)],
    brand_range = {
      same  <- brand[is_range & owner == brand_owner]       # ranges of the winning owner
      other <- brand[is_range]                               # any range at all
      if (length(same) > 0) same[which.max(nchar(same))]
      else if (length(other) > 0) other[which.max(nchar(other))]
      else brand_owner
    },
    .groups = "drop")

nrow(brand_final)                                          # should equal the number of products in fr_clean
brand_final %>% count(brand_owner, sort = TRUE) %>% print(n=30)   # biggest owners

# part 4: write the two new columns back to fr_clean, matched on the barcode
dbWriteTable(con, "brand_final", brand_final, overwrite = TRUE)
dbExecute(con, "CREATE OR REPLACE TABLE fr_clean AS
                SELECT f.*, b.brand_owner, b.brand_range
                FROM fr_clean f LEFT JOIN brand_final b USING (code)")
dbGetQuery(con, "SELECT COUNT(*) AS n_products,
                        COUNT(brand_owner) AS n_with_owner,
                        COUNT(DISTINCT brand_owner) AS n_owners,
                        COUNT(DISTINCT brand_range) AS n_ranges
                 FROM fr_clean")

# 7.3o brands: drop products whose brand is sans marque, which means no brand, same as a missing brand
dbExecute(con, "DELETE FROM fr_clean WHERE brand_owner = 'sans marque'")
dbGetQuery(con, "SELECT COUNT(*) AS n_after_sans_marque FROM fr_clean")   # expect 401,774 minus 1,708 = 400,066

# 7.3p brands: find parent links from brands listed together, list them only, change nothing yet
#      a child brand belongs to a parent when all of these are true:
#      they appear together on 20 or more products, that is at least 25% of the child's products,
#      the parent pairs with more different brands than the child, and the parent has more products

owner_prod <- prod %>% distinct(code, owner)   # each product with each owner it lists

# every pair of different owners listed on the same product, and on how many products
pairs_o <- owner_prod %>%
  inner_join(owner_prod, by = "code", relationship = "many-to-many") %>%
  filter(owner.x != owner.y) %>%
  count(child = owner.x, parent = owner.y, name = "shared")

# how many different partners each owner has (only partners shared on 5 or more products count)
degree <- pairs_o %>% filter(shared >= 5) %>% count(parent, name = "n_partners")

links <- pairs_o %>%
  left_join(owner_size %>% rename(child  = owner, child_products  = owner_products), by = "child") %>%
  left_join(owner_size %>% rename(parent = owner, parent_products = owner_products), by = "parent") %>%
  left_join(degree %>% rename(parent_partners = n_partners), by = "parent") %>%
  left_join(degree %>% rename(child = parent, child_partners = n_partners), by = "child") %>%
  mutate(parent_partners = coalesce(parent_partners, 0L),
         child_partners  = coalesce(child_partners, 0L),
         share = round(shared / child_products, 2)) %>%                    # share of the child's products
  filter(shared >= 20, share >= 0.25,
         parent_partners > child_partners, parent_products > child_products) %>%
  group_by(child) %>%
  slice_max(shared, n = 1, with_ties = FALSE) %>%                         # one parent per child
  ungroup() %>%
  arrange(parent, desc(shared))

nrow(links)   # number of proposed parent links
write.csv(links, file.path(dir, "parent_links_7_3p.csv"), row.names = FALSE)   # to review together

# 7.3q brands: apply the reviewed parent links and update fr_clean

# part 1: the approved links, minus the 8 rejected ones, plus les mousquetaires under intermarche
rejected <- c("lavazza","ebro foods","agrial","selection","sante","veggie","classique","nature bio")
parent_map <- links %>%
  filter(!child %in% rejected) %>%
  select(child, parent) %>%
  bind_rows(tibble(child = "les mousquetaires", parent = "intermarche"))

nrow(parent_map)   # number of links applied, expect 234

write.csv(parent_map, file.path(dir, "parent_map_7_3q.csv"), row.names = FALSE)   # kept in the cleaning log

# part 2: replace each child owner by its parent; done twice so chains such as
# le rustique, then cf & r, then savencia end at the top parent; the range is kept unchanged
apply_parents <- function(df) {
  df %>%
    left_join(parent_map, by = c("brand_owner" = "child")) %>%
    mutate(brand_owner = coalesce(parent, brand_owner)) %>%
    select(-parent)
}
brand_final <- brand_final %>% apply_parents() %>% apply_parents()

# part 3: write the updated owner and range back to fr_clean, replacing the old columns
dbWriteTable(con, "brand_final", brand_final, overwrite = TRUE)
dbExecute(con, "CREATE OR REPLACE TABLE fr_clean AS
                SELECT f.* EXCLUDE (brand_owner, brand_range), b.brand_owner, b.brand_range
                FROM fr_clean f LEFT JOIN brand_final b USING (code)")

# check: totals and the 30 biggest owners after the links
dbGetQuery(con, "SELECT COUNT(*) AS n_products,
                        COUNT(DISTINCT brand_owner) AS n_owners,
                        COUNT(DISTINCT brand_range) AS n_ranges
                 FROM fr_clean")
dbGetQuery(con, "SELECT brand_owner, COUNT(*) AS n_products
                 FROM fr_clean GROUP BY brand_owner
                 ORDER BY n_products DESC LIMIT 30")

# 7.4 quantity: number of different values, number empty, and the 30 most common
#     quantity is free text such as 500 g, 1 l or 6 x 125 g, so we look at how it is written
col_check("quantity")

# 7.4b quantity: extract the unit written after the number, and list every unique unit with its count
qty <- dbGetQuery(con, "SELECT code, quantity FROM fr_clean WHERE quantity IS NOT NULL AND trim(quantity) <> ''") %>%
  mutate(q = str_to_lower(str_squish(quantity)))   # lowercase and tidy spaces

# a unit is the letters written right after a number, for example the g in 500 g or the cl in 33cl
# when there are several, such as 4 x 125 g, the last one is the real unit
unit_list <- str_extract_all(qty$q, "(?<=\\d)\\s*[a-zµ]+")
qty$unit  <- sapply(unit_list, function(u) if (length(u) == 0) NA else str_trim(tail(u, 1)))

units <- qty %>% count(unit, sort = TRUE) %>% mutate(pct = round(100 * n / sum(n), 2))
nrow(units)                 # number of unique units
print(head(units, 40))   # the 40 most common units

# 7.4c quantity: convert weights to grams and volumes to millilitres, in R only, fr_clean is not changed yet

# conversion table: each unit, what to multiply by, and whether it is a weight or a volume
conv <- tribble(
  ~unit,     ~factor, ~type,
  "g",        1,      "weight",  "gr",      1,      "weight",  "grs",     1,      "weight",
  "gm",       1,      "weight",  "gram",    1,      "weight",  "grams",   1,      "weight",
  "gramme",   1,      "weight",  "grammes", 1,      "weight",  "kg",      1000,   "weight",
  "mg",       0.001,  "weight",  "oz",      28.35,  "weight",  "lb",      453.6,  "weight",
  "ml",       1,      "volume",  "cl",      10,     "volume",  "dl",      100,    "volume",
  "l",        1000,   "volume",  "litre",   1000,   "volume",  "litres",  1000,   "volume",
  "liter",    1000,   "volume",  "liters",  1000,   "volume",  "fl",      29.57,  "volume")

# read one quantity text and return the number and its unit
#   packs such as 4 x 125 g are multiplied out to 500 g
#   otherwise the first number followed by a known unit is used, for example 500 g in 500 g (2 x 250 g)
#   decimal commas are read as dots, so 1,5 l becomes 1.5 l
parse_qty <- function(q) {
  pack <- str_match(q, "(\\d+)\\s*x\\s*(\\d+(?:[.,]\\d+)?)\\s*([a-z]+)")
  if (!is.na(pack[1]) && pack[4] %in% conv$unit) {
    return(c(as.numeric(pack[2]) * as.numeric(sub(",", ".", pack[3])), pack[4]))
  }
  pairs <- str_match_all(q, "(\\d+(?:[.,]\\d+)?)\\s*([a-z]+)")[[1]]
  for (i in seq_len(nrow(pairs))) {
    if (pairs[i, 3] %in% conv$unit) return(c(as.numeric(sub(",", ".", pairs[i, 2])), pairs[i, 3]))
  }
  c(NA, NA)
}

qty <- qty %>% mutate(q = stri_trans_general(q, "Latin-ASCII"))   # remove accents first, pièces becomes pieces

parsed <- lapply(qty$q, parse_qty)                                 # takes a minute or two on 330,000 rows
qty$qty_number <- as.numeric(sapply(parsed, `[`, 1))
qty$qty_unit   <- sapply(parsed, `[`, 2)

qty <- qty %>%
  left_join(conv, by = c("qty_unit" = "unit")) %>%
  mutate(quantity_value = qty_number * factor,   # grams for weights, millilitres for volumes
         quantity_type  = type)

# how many could be converted
qty %>% count(quantity_type) %>% mutate(pct = round(100 * n / sum(n), 1))


# 7.4d quantity: check the converted numbers for impossible values, per type
qty %>%
  filter(!is.na(quantity_type)) %>%
  group_by(quantity_type) %>%
  summarise(n          = n(),
            n_zero_neg = sum(quantity_value <= 0),                 # zero or negative, impossible
            min        = min(quantity_value),
            p1         = quantile(quantity_value, 0.01),           # 1% of products are below this
            median     = median(quantity_value),
            p99        = quantile(quantity_value, 0.99),           # 99% of products are below this
            max        = max(quantity_value))

# the 20 largest and the 20 smallest, with the original text, to judge them by eye
qty %>% filter(!is.na(quantity_type)) %>% arrange(desc(quantity_value)) %>%
  select(quantity, quantity_value, quantity_type) %>% head(20)
qty %>% filter(!is.na(quantity_type)) %>% arrange(quantity_value) %>%
  select(quantity, quantity_value, quantity_type) %>% head(20)

# 7.4e quantity: fix the three reading bugs, read again, then apply the plausible limits

# part 1: tidy number formats in the text before reading it
qty <- qty %>%
  mutate(q = q %>%
           str_replace_all("(\\d)\\s*,\\s*(\\d)", "\\1.\\2") %>%    # 0, 766 kg becomes 0.766 kg
           str_replace_all("(\\d)\\s(\\d{3})(?!\\d)", "\\1\\2") %>%  # 1 000 g becomes 1000 g
           str_replace_all("(?<!\\d)\\.(\\d)", "0.\\1"))             # .70 l becomes 0.70 l

# part 2: read again with the same parse_qty and conversion table as 7.4c
parsed <- lapply(qty$q, parse_qty)
qty$qty_number <- as.numeric(sapply(parsed, `[`, 1))
qty$qty_unit   <- sapply(parsed, `[`, 2)

qty <- qty %>%
  select(-factor, -type, -quantity_value, -quantity_type) %>%   # drop the results of the first reading
  left_join(conv, by = c("qty_unit" = "unit")) %>%
  mutate(quantity_value = qty_number * factor,
         quantity_type  = type)

# part 3: values below 1 g or 1 ml, or above 25 kg or 25 l (25,000 ml), are not plausible shop packs
qty <- qty %>%
  mutate(out_of_range   = !is.na(quantity_value) & (quantity_value < 1 | quantity_value > 25000),
         quantity_value = ifelse(out_of_range, NA, quantity_value),
         quantity_type  = ifelse(out_of_range, NA, quantity_type))

sum(qty$out_of_range)   # how many values were set to NA by the limits

# check again: the summary per type should now look sensible
qty %>%
  filter(!is.na(quantity_type)) %>%
  group_by(quantity_type) %>%
  summarise(n = n(), min = min(quantity_value), median = median(quantity_value), max = max(quantity_value))

# 7.4f quantity: write quantity_value and quantity_type back to fr_clean, matched on the barcode
qty_final <- qty %>% select(code, quantity_value, quantity_type)
dbWriteTable(con, "qty_final", qty_final, overwrite = TRUE)

dbExecute(con, "CREATE OR REPLACE TABLE fr_clean AS
                SELECT f.*, q.quantity_value, q.quantity_type
                FROM fr_clean f LEFT JOIN qty_final q USING (code)")

# check: share of products with a usable quantity, out of all products
dbGetQuery(con, "SELECT quantity_type, COUNT(*) AS n_products,
                        ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
                 FROM fr_clean GROUP BY quantity_type")

# 7.5 main_category_en: number of different categories, number empty, and the 30 most common
col_check("main_category_en")

# 7.5b main_category_en: minimal clean into a new column category_detail, the original stays untouched
#      removes language prefixes such as en: or fr:, lowercases, turns hyphens into spaces,
#      and treats the vague catch alls groceries and autres produits as empty
dbExecute(con, "ALTER TABLE fr_clean ADD COLUMN IF NOT EXISTS category_detail VARCHAR")
dbExecute(con, "UPDATE fr_clean
                SET category_detail = trim(replace(lower(regexp_replace(main_category_en, '^[a-zA-Z]{2}:', '')), '-', ' '))")
dbExecute(con, "UPDATE fr_clean
                SET category_detail = NULL
                WHERE category_detail IN ('groceries', 'autres produits', '')")

# check: unique values before and after, and how many are empty now
dbGetQuery(con, "SELECT COUNT(DISTINCT main_category_en) AS n_before,
                        COUNT(DISTINCT category_detail)  AS n_after,
                        COUNT(*) - COUNT(category_detail) AS n_empty
                 FROM fr_clean")

# 7.6 pnns groups: the official French food groups, broad level and sub level
col_check("pnns_groups_1")
col_check("pnns_groups_2")




#     result: group 1 has 11 groups, group 2 has 41 sub groups; unknown in 61,224 products, plus 600 empty

#---------------------------------------NOTE: FROM HERE THE STEPS RUN IN CLAUDE'S WORKSPACE
# fr_clean was exported once with COPY fr_clean TO 'fr_clean.parquet' (FORMAT parquet)
# the steps below run on a copy loaded from that file; the cleaned table is exported back at the end

# 7.6b pnns groups: unknown is a placeholder for a missing group, so it becomes a real empty value
#      the products stay, only the label is removed
dbExecute(con, "UPDATE fr_clean SET pnns_groups_1 = NULL WHERE pnns_groups_1 = 'unknown'")
dbExecute(con, "UPDATE fr_clean SET pnns_groups_2 = NULL WHERE pnns_groups_2 = 'unknown'")
dbGetQuery(con, "SELECT COUNT(*) - COUNT(pnns_groups_1) AS n_empty_group_1,
                        COUNT(*) - COUNT(pnns_groups_2) AS n_empty_group_2,
                        COUNT(DISTINCT pnns_groups_1)   AS n_groups_1,
                        COUNT(DISTINCT pnns_groups_2)   AS n_groups_2
                 FROM fr_clean")
#     result: 61,224 unknown set to empty, so 61,824 products (15.5%) have no food group in both columns

# 7.7 nutriscore: how the grade is written, and whether the score fits each grade
#     result: grades a to e are clean; unknown in 61,031 products (not enough data to grade),
#     not-applicable in 23,535 (excluded by the official rules, mostly alcohol and baby food)
dbGetQuery(con, "SELECT nutriscore_grade, COUNT(*) AS n_products,
                        MIN(TRY_CAST(nutriscore_score AS INTEGER)) AS min_score,
                        MAX(TRY_CAST(nutriscore_score AS INTEGER)) AS max_score
                 FROM fr_clean GROUP BY nutriscore_grade ORDER BY n_products DESC")

# 7.7b nutriscore: keep only real grades a to e, and record why the others have no grade
#      nutriscore_status is graded, not applicable or unknown
dbExecute(con, "ALTER TABLE fr_clean ADD COLUMN IF NOT EXISTS nutriscore_status VARCHAR")
dbExecute(con, "UPDATE fr_clean SET nutriscore_status = CASE
                  WHEN nutriscore_grade IN ('a','b','c','d','e') THEN 'graded'
                  WHEN nutriscore_grade = 'not-applicable'        THEN 'not applicable'
                  ELSE 'unknown' END")
dbExecute(con, "UPDATE fr_clean SET nutriscore_grade = NULL, nutriscore_score = NULL
                WHERE nutriscore_grade NOT IN ('a','b','c','d','e') OR nutriscore_grade IS NULL")
dbGetQuery(con, "SELECT nutriscore_status, COUNT(*) AS n_products, COUNT(nutriscore_grade) AS n_with_grade
                 FROM fr_clean GROUP BY 1 ORDER BY 2 DESC")
#      result: 314,814 graded (78.7%), 61,717 unknown, 23,535 not applicable

# 7.8 nova_group: level of processing from 1 (unprocessed) to 4 (ultra processed)
dbGetQuery(con, "SELECT nova_group, COUNT(*) AS n_products FROM fr_clean GROUP BY 1 ORDER BY 1")
#     result: only values 1 to 4, no placeholders; 108,959 empty (27%); no fix needed

# 7.9 additives: number of additives per product, and whether the list matches the count
dbGetQuery(con, "SELECT MIN(TRY_CAST(additives_n AS INTEGER)) AS min_n, MAX(TRY_CAST(additives_n AS INTEGER)) AS max_n,
                        COUNT(additives_n) AS n_with_count, COUNT(additives_en) AS n_with_list,
                        SUM(CASE WHEN TRY_CAST(additives_n AS INTEGER) > 0 AND additives_en IS NULL THEN 1 ELSE 0 END) AS count_but_no_list,
                        SUM(CASE WHEN additives_en IS NOT NULL AND TRY_CAST(additives_n AS INTEGER) <>
                                 len(string_split(additives_en, ',')) THEN 1 ELSE 0 END) AS count_list_mismatch
                 FROM fr_clean")
dbGetQuery(con, "SELECT TRY_CAST(additives_n AS INTEGER) AS n_additives, COUNT(*) AS n_products
                 FROM fr_clean GROUP BY 1 ORDER BY 1 LIMIT 40")
dbGetQuery(con, "SELECT trim(a) AS additive, COUNT(*) AS n_products
                 FROM (SELECT unnest(string_split(additives_en, ',')) AS a FROM fr_clean WHERE additives_en IS NOT NULL)
                 GROUP BY 1 ORDER BY 2 DESC LIMIT 15")
#     result: count runs 0 to 33 plus one 78; the list names family and specific codes (E322 and E322i),
#     so it can be longer than the count; the count is the number to trust

# 7.9b additives: Milka Caramel lists 78 additives including silver and gold, a clear data error, so it is emptied
dbExecute(con, "UPDATE fr_clean SET additives_n = NULL, additives_en = NULL WHERE code = '7622202313042'")
dbGetQuery(con, "SELECT MAX(TRY_CAST(additives_n AS INTEGER)) AS max_additives FROM fr_clean")
#      result: maximum is now 33

# 7.10 allergens: the 14 official EU allergens are written as fixed english names when Open Food Facts recognises them;
#      unrecognised values keep their raw text with a language prefix, such as fr:Noisettes or de:Mandelmasse
#      result: 5,406 unique unrecognised values; translated with the Open Food Facts allergen dictionary
#      (off_allergens_taxonomy.txt, from their GitHub) and, for what it does not cover, multilingual stem rules
#      written and reviewed by an AI model, then spot checked; verdicts saved in allergens_no_match_verdicts_7_10.csv

# 7.10b allergens: build allergens_clean (official 14 only) and allergens_other (known extras such as pork or apple)
official <- c("milk","gluten","eggs","soybeans","nuts","fish","mustard","sulphur dioxide and sulphites",
              "celery","sesame seeds","peanuts","crustaceans","molluscs","lupin")

# normalised key: no accents, lowercase, no language prefix, no brackets, only letters digits and spaces
norm <- function(s) s %>% stri_trans_general("Latin-ASCII") %>% str_to_lower() %>% str_replace("^[a-z]{2}:", "") %>%
  str_replace_all("\\(.*?\\)", " ") %>% str_replace_all("[^a-z0-9 ]", " ") %>% str_squish()

# part 1: read the Open Food Facts dictionary; blocks are separated by blank lines and the first english name is the allergen
lines <- readLines(file.path(dir, "off_allergens_taxonomy.txt"), encoding = "UTF-8")
dict <- list(); canon <- NA
for (l in lines) {
  if (str_trim(l) == "") { canon <- NA; next }
  if (str_detect(l, "^stopwords|^synonyms|^#|^<")) next
  m <- str_match(l, "^([a-z]{2}):\\s*(.*)$")
  if (is.na(m[1])) next
  terms <- str_split(m[3], ",")[[1]]
  if (is.na(canon) && m[2] == "en") canon <- str_trim(terms[1])
  if (!is.na(canon)) dict[[length(dict) + 1]] <- tibble(term = norm(terms), allergen = canon)
}
dict <- bind_rows(dict) %>% filter(term != "") %>% distinct(term, .keep_all = TRUE)
long_terms <- dict %>% filter(nchar(term) >= 4, allergen != "none")   # words of 4 or more letters, safe to find inside a value

# stem rules for allergen values the dictionary could not read, checked in this order, first match wins
# keys are normalised text: no accents, lowercase, only letters digits and spaces
stem_rules <- tribble(
  ~allergen,                        ~pattern,
  "gluten",      "gruau|bouglour|\\bnisu|\\bbl\\b|\\bvete|avoine|\\bvoine\\b|avena|\\boat|hafer|haver|ovesn|ovsen|\\bble\\b|\\bbie\\b|\\bble[ s]|weizen|wheat|tarwe|psenic|frumento|farine|chapelure|paniermehl|seigle|roggen|\\brye\\b|rogge|rugmel|\\borge\\b|gerst|barley|\\bmalt|epeautre|peautre|dinkel|spelt|grunkern|kamut|triticale|semoule|semolina|boulghour|bulgur|couscous|\\bpates?\\b|pasta|vermicelle|nouilles|crusca|\\bson\\b|\\bpain\\b|biscuit|levain|sauerteig|vehna|gluten",
  "milk",        "\\blair\\b|lactos|\\bzola\\b|\\blait|\\biait|\\blai\\b|\\blat\\b|lalt|\\balit\\b|milk|milch|\\bmelk|latte|leche|beurre|butter|burro|boter|fromag|cheese|formaggio|\\bkase|\\bkaas|maasdam|beaufort|cantal|\\bbrie\\b|\\btome\\b|tomme|maroilles|provolone|moz+arella|parmig|scamorza|metton|\\bsere\\b|yogh?o?urt|yogur|\\bcreme|sahne|\\bobers|molke|whey|serum|lactoserum|iactoserum|butyrique|ecreme|chevre|\\bvache|lactee|bufflemilch|buffelmilch|margarine",
  "eggs",        "jaune d|\\boeuf|\\bceufs?\\b|\\beuf\\b|\\bufs?\\b|\\begg|\\beier|eigeel|eigelb|huhnerei|omelette|lysozyme|\\beiweiss",
  "peanuts",     "zemesrieks|arachide|cacahu|peanut|erdnuss|pinda",
  "nuts",        "mandl|noisette|hazel|amande|almond|mandel|\\bnoix\\b(?! de coco)|cajou|cashew|anacardi|pistach|pecan|macadamia|nusskern|\\bnuss|lesnik|fruits? a coque|praline",
  "soybeans",    "\\bsoja|\\bsoy|okara|tamari|sojabloem",
  "fish",        "thazard|poisson|\\bfish|fisch|\\bvis\\b|\\bthon\\b|tonno|tuna|saumon|lachs|cabillaud|gadus|morue|eglefin|haddock|merlu|\\bcolin|theragra|\\blieu\\b|sardin|sardell|anchois|sprat|maquereau|cavala|mackerel|bonite|bonito|dorade|\\bcarpe\\b|\\braie\\b|\\bplie\\b|congre|\\bmulet\\b|grondin|espadon|marlin|\\blotte\\b|esturgeon|lompe|truite|surimi",
  "crustaceans", "crevette|garnel|garnalen|shrimp|prawn|\\bcrabe|tourteau|homard|langoust|ecrevisse|crustac|fruits de mer",
  "molluscs",    "\\bmoules?\\b|huitre|bulot|palourde|\\bcoques?\\b|\\bvenus\\b|calamar|encornet|poulpe|pieuvre|seiche|escargot|scargot|mollus|\\barches\\b",
  "sulphur dioxide and sulphites", "bisul|sulfi|sulphi|sulfu|soufre|\\bso2|metabisulf|disulf|bisulf|dissulf|suflite|\\be22[0-8]\\b|anhydride|anhydre",
  "mustard",     "moutard|\\bsenf|mustard|mosterd",
  "celery",      "celeri|sellerie|selder|celery",
  "sesame seeds","c?esam",
  "lupin",       "lupin",
  "chicken",     "poulet|chicken",
  "pork",        "\\bporc\\b|\\bpork",
  "beef",        "boeuf|\\bbeef|bovine",
  "apple",       "\\bpommes?\\b(?! de terre)",
  "peach",       "\\bpeche\\b",
  "banana",      "banane",
  "orange",      "\\borange|clementine|mandarine",
  "kiwi",        "\\bkiwi")
# scripts other than latin are checked on the raw text before normalising
raw_rules <- tribble(~allergen, ~pattern,
  "gluten", "小麦|овес", "nuts", "アーモンド|миндал|орех", "soybeans", "大豆", "milk", "乳|мляко|молок", "eggs", "卵", "sesame seeds", "ごま", "apple", "りんご")

# part 2: one value can hold several allergens, so every match is kept
classify <- function(raw) {
  if (raw %in% official) return(raw)                                   # already a standard name
  k <- norm(raw)
  exact <- dict$allergen[dict$term == k]                               # whole value is a dictionary word
  if (length(exact) > 0) return(exact[1])
  hits <- raw_rules$allergen[str_detect(raw, raw_rules$pattern)]       # non latin scripts
  hits <- c(hits, long_terms$allergen[str_detect(k, paste0("\\b", long_terms$term, "\\b"))][1])
  hits <- c(hits, stem_rules$allergen[str_detect(k, stem_rules$pattern)])
  hits <- unique(hits[!is.na(hits)])
  # nut butters are not milk, and fruits a coque are nuts not molluscs
  if (any(hits %in% c("nuts","peanuts")) && str_detect(k, "(nuss|nut|cashew|mandel|almond|peanut)\\s?butter")) hits <- setdiff(hits, "milk")
  if (str_detect(k, "fruits? a coque")) hits <- setdiff(hits, "molluscs")
  if (length(hits) == 0) NA_character_ else paste(hits, collapse = ",")
}

# part 3: classify every unique raw value once, then attach the result to each product
pairs <- dbGetQuery(con, "SELECT code, trim(a) AS raw
                          FROM (SELECT code, unnest(string_split(allergens_en, ',')) AS a FROM fr_clean WHERE allergens_en IS NOT NULL)")
lookup <- tibble(raw = unique(pairs$raw)) %>% mutate(allergen = sapply(raw, classify))

allergen_final <- pairs %>%
  left_join(lookup, by = "raw") %>%
  filter(!is.na(allergen), allergen != "none") %>%
  separate_rows(allergen, sep = ",") %>%
  distinct(code, allergen) %>%
  group_by(code) %>%
  summarise(allergens_clean = paste(sort(allergen[allergen %in% official]), collapse = ","),
            allergens_other = paste(sort(allergen[!allergen %in% official]), collapse = ","),
            .groups = "drop") %>%
  mutate(across(c(allergens_clean, allergens_other), ~ na_if(.x, "")))

# part 4: write both columns back to fr_clean, matched on the barcode; the original allergens_en stays
dbWriteTable(con, "allergen_final", allergen_final, overwrite = TRUE)
dbExecute(con, "CREATE OR REPLACE TABLE fr_clean AS
                SELECT f.*, a.allergens_clean, a.allergens_other
                FROM fr_clean f LEFT JOIN allergen_final a USING (code)")
dbGetQuery(con, "SELECT COUNT(allergens_en) AS n_with_raw, COUNT(allergens_clean) AS n_with_official,
                        COUNT(allergens_other) AS n_with_other FROM fr_clean")
dbGetQuery(con, "SELECT trim(a) AS allergen, COUNT(*) AS n_products
                 FROM (SELECT unnest(string_split(allergens_clean, ',')) AS a FROM fr_clean WHERE allergens_clean IS NOT NULL)
                 GROUP BY 1 ORDER BY 2 DESC")
#      result: 192,631 products with at least one official allergen (raw column: 197,941), 4,281 with known extras;
#      the rest only had junk or none; milk 106,786, gluten 91,312, eggs 43,152 lead

# 7.11 nutrients per 100 g: numbers stored as text, checked for values that cannot be true
#      grams per 100 g must sit between 0 and 100, energy between 0 and 900 kcal (pure fat is 900),
#      saturated fat cannot exceed fat, sugars cannot exceed carbohydrates
nutr <- c("energy-kcal_100g","fat_100g","saturated-fat_100g","carbohydrates_100g","sugars_100g",
          "fiber_100g","proteins_100g","salt_100g","alcohol_100g")
checks <- lapply(nutr, function(c) {
  q <- sprintf('"%s"', c); upper <- ifelse(c == "energy-kcal_100g", 900, 100)
  dbGetQuery(con, sprintf("SELECT '%s' AS nutrient, COUNT(%s) AS n_filled,
                                  SUM(CASE WHEN %s IS NOT NULL AND TRY_CAST(%s AS DOUBLE) IS NULL THEN 1 ELSE 0 END) AS n_not_number,
                                  SUM(CASE WHEN TRY_CAST(%s AS DOUBLE) < 0 THEN 1 ELSE 0 END) AS n_negative,
                                  SUM(CASE WHEN TRY_CAST(%s AS DOUBLE) > %d THEN 1 ELSE 0 END) AS n_too_high,
                                  MEDIAN(TRY_CAST(%s AS DOUBLE)) AS median, MAX(TRY_CAST(%s AS DOUBLE)) AS max
                           FROM fr_clean", c, q, q, q, q, q, upper, q, q))
})
bind_rows(checks)
dbGetQuery(con, 'SELECT SUM(CASE WHEN TRY_CAST("saturated-fat_100g" AS DOUBLE) > TRY_CAST(fat_100g AS DOUBLE) THEN 1 ELSE 0 END) AS satfat_above_fat,
                        SUM(CASE WHEN TRY_CAST(sugars_100g AS DOUBLE) > TRY_CAST(carbohydrates_100g AS DOUBLE) THEN 1 ELSE 0 END) AS sugars_above_carbs
                 FROM fr_clean')
#     result: all values are numbers; a few hundred impossible values (238 energies above 900 kcal, 37 negatives,
#     maximums such as 4.6e11 g salt); saturated fat above fat in 484 products, sugars above carbohydrates in 538

# 7.11b nutrients: convert to numbers, then empty values that cannot be true; the products stay
nutr <- c("energy-kcal_100g","fat_100g","saturated-fat_100g","carbohydrates_100g","sugars_100g",
          "fiber_100g","proteins_100g","salt_100g","alcohol_100g")
for (c in nutr) {
  q <- sprintf('"%s"', c); upper <- ifelse(c == "energy-kcal_100g", 900, 100)
  dbExecute(con, sprintf("ALTER TABLE fr_clean ALTER COLUMN %s TYPE DOUBLE USING TRY_CAST(%s AS DOUBLE)", q, q))   # text becomes a number
  dbExecute(con, sprintf("UPDATE fr_clean SET %s = NULL WHERE %s < 0 OR %s > %d", q, q, q, upper))               # impossible values
}

# saturated fat is part of fat and sugars are part of carbohydrates, so they cannot be larger (0.5 g rounding margin)
dbExecute(con, 'UPDATE fr_clean SET "saturated-fat_100g" = NULL WHERE "saturated-fat_100g" > fat_100g + 0.5')
dbExecute(con, 'UPDATE fr_clean SET sugars_100g = NULL WHERE sugars_100g > carbohydrates_100g + 0.5')

# check: filled values and range of each nutrient after cleaning
bind_rows(lapply(nutr, function(c) dbGetQuery(con, sprintf(
  "SELECT '%s' AS nutrient, COUNT(\"%s\") AS n_filled, MIN(\"%s\") AS min, MEDIAN(\"%s\") AS median, MAX(\"%s\") AS max FROM fr_clean", c, c, c, c, c))))
#      result: all nutrients are now numbers between 0 and 100 g (energy 0 to 900 kcal); 183 saturated fat and
#      303 sugar values emptied by the logic rules; medians unchanged (246 kcal, 7 g fat, 3.5 g sugar)

# 7.12 labels_en: certifications and claims printed on the pack, such as organic, fair trade or no palm oil
#      one product can carry several labels separated by commas
dbGetQuery(con, "SELECT COUNT(labels_en) AS n_with_labels, COUNT(*) AS n_total FROM fr_clean")
dbGetQuery(con, "SELECT COUNT(DISTINCT trim(a)) AS n_unique_labels
                 FROM (SELECT unnest(string_split(labels_en, ',')) AS a FROM fr_clean WHERE labels_en IS NOT NULL)")
dbGetQuery(con, "SELECT trim(a) AS label, COUNT(*) AS n_products
                 FROM (SELECT unnest(string_split(labels_en, ',')) AS a FROM fr_clean WHERE labels_en IS NOT NULL)
                 GROUP BY 1 ORDER BY 2 DESC LIMIT 30")
#     result: 261,924 products (65%) have labels, 14,368 different values; labels come in families (Organic with
#     EU Organic, AB and FR-BIO codes); 13,307 values are untranslated (fr:...), 10,462 appear only once

# 7.12b labels: yes or no columns for the claims visitors ask about, detected in english and french label text
#      text is lowercased, accents removed and hyphens turned into spaces before matching; labels_en stays as it is
lab <- dbGetQuery(con, "SELECT code, labels_en FROM fr_clean WHERE labels_en IS NOT NULL") %>%
  mutate(t = labels_en %>% stri_trans_general("Latin-ASCII") %>% str_to_lower() %>% str_replace_all("-", " "))

label_flags <- tribble(
  ~flag,            ~pattern,
  "is_organic",     "\\borganic|\\bbio\\b|biologique|\\bab agriculture|\\b[a-z]{2} bio \\d|demeter|nature et progres|bio equitable",
  "is_vegan",       "\\bvegan|vegetalien",
  "is_vegetarian",  "vegetarian|vegetarien|\\bvegan|vegetalien",
  "is_fair_trade",  "fair ?trade|equitable|max havelaar",
  "no_gluten",      "no gluten|gluten free|sans gluten",
  "no_lactose",     "no lactose|lactose free|sans lactose",
  "no_palm_oil",    "no palm oil|palm oil free|sans huile de palme",
  "no_added_sugar", "no added sugar|sans sucres? ajoutes?",
  "made_in_france", "made in france|origine france|origine de france|fabrique en france|produit en france|\\bfrench\\b|(ble|porc|lait|boeuf|veau|volaille|viande|farine de ble|oeufs?) francais|de france\\b(?! (bio|agriculture))")

for (i in seq_len(nrow(label_flags))) lab[[label_flags$flag[i]]] <- str_detect(lab$t, label_flags$pattern[i])

# write the flags back to fr_clean; products without any label get false, because no claim is printed
label_final <- lab %>% select(code, all_of(label_flags$flag))
dbWriteTable(con, "label_final", label_final, overwrite = TRUE)
for (fl in label_flags$flag) dbExecute(con, sprintf("ALTER TABLE fr_clean DROP COLUMN IF EXISTS %s", fl))   # so the step can be rerun safely
dbExecute(con, paste0("CREATE OR REPLACE TABLE fr_clean AS SELECT f.*, ",
                      paste0("COALESCE(l.", label_flags$flag, ", false) AS ", label_flags$flag, collapse = ", "),
                      " FROM fr_clean f LEFT JOIN label_final l USING (code)"))

# check: number of products with each claim
dbGetQuery(con, paste0("SELECT ", paste0("SUM(CASE WHEN ", label_flags$flag, " THEN 1 ELSE 0 END) AS ", label_flags$flag, collapse = ", "), " FROM fr_clean"))
#      result: organic 68,132, made in france 51,868, no gluten 23,684, vegetarian 21,734, vegan 16,129,
#      no added sugar 9,243, no palm oil 8,098, fair trade 7,816, no lactose 4,813
#      check of made in france: matched labels are Made in France, French meat, French pork, fr:origine-france and similar

# 7.13 packaging_en: what the pack is made of and its shape, such as plastic, glass, cardboard, bottle or can
dbGetQuery(con, "SELECT COUNT(packaging_en) AS n_with_packaging, COUNT(*) AS n_total FROM fr_clean")
dbGetQuery(con, "SELECT trim(a) AS packaging, COUNT(*) AS n_products
                 FROM (SELECT unnest(string_split(packaging_en, ',')) AS a FROM fr_clean WHERE packaging_en IS NOT NULL)
                 GROUP BY 1 ORDER BY 2 DESC LIMIT 25")
#     result: 179,976 products (45%) have packaging; it mixes material (plastic, glass), shape (bag, bottle)
#     and storage (fresh, frozen); 12,320 different values, 11,918 untranslated such as fr:film-en-plastique

# 7.13b packaging: yes or no columns for material and frozen storage, detected in english and french text
#      text is lowercased, accents removed and hyphens turned into spaces before matching; packaging_en stays as it is
pk <- dbGetQuery(con, "SELECT code, packaging_en FROM fr_clean WHERE packaging_en IS NOT NULL") %>%
  mutate(t = packaging_en %>% stri_trans_general("Latin-ASCII") %>% str_to_lower() %>% str_replace_all("-", " "))

pack_flags <- tribble(
  ~flag,                  ~pattern,
  "pack_plastic",         "plasti|\\bpet\\b|\\bpp\\b|\\bpe\\b|\\bpehd|\\bhdpe|\\bldpe|\\bpse?\\b|polyst|polyprop|polyeth|\\bfilm",
  "pack_glass",           "glass|\\bverre|\\bbocal",
  "pack_paper_cardboard", "cardboard|carton|paper|papier|\\bbrick|\\bbrique|tetra",
  "pack_metal",           "metal|alumini|\\bacier|steel|\\btin\\b|\\bcans?\\b|canned|conserve|canette|boite metal",
  "is_frozen",            "frozen|surgel|congel")

for (i in seq_len(nrow(pack_flags))) pk[[pack_flags$flag[i]]] <- str_detect(pk$t, pack_flags$pattern[i])

# write the flags back to fr_clean; products without packaging information get false
pack_final <- pk %>% select(code, all_of(pack_flags$flag))
dbWriteTable(con, "pack_final", pack_final, overwrite = TRUE)
for (fl in pack_flags$flag) dbExecute(con, sprintf("ALTER TABLE fr_clean DROP COLUMN IF EXISTS %s", fl))   # so the step can be rerun safely
dbExecute(con, paste0("CREATE OR REPLACE TABLE fr_clean AS SELECT f.*, ",
                      paste0("COALESCE(p.", pack_flags$flag, ", false) AS ", pack_flags$flag, collapse = ", "),
                      " FROM fr_clean f LEFT JOIN pack_final p USING (code)"))

# check: number of products with each flag
dbGetQuery(con, paste0("SELECT ", paste0("SUM(CASE WHEN ", pack_flags$flag, " THEN 1 ELSE 0 END) AS ", pack_flags$flag, collapse = ", "), " FROM fr_clean"))
#      result: plastic 88,777, paper or cardboard 44,159, glass 25,613, metal 22,485, frozen 8,202

# 7.14 environmental_score_grade: the Eco-Score, an A to E grade of a product's environmental impact
dbGetQuery(con, "SELECT environmental_score_grade, COUNT(*) AS n_products FROM fr_clean GROUP BY 1 ORDER BY 2 DESC")

# 7.15 countries_en: every country where the product has been seen on sale (France is always in it)
dbGetQuery(con, "SELECT len(string_split(countries_en, ',')) AS n_countries, COUNT(*) AS n_products FROM fr_clean GROUP BY 1 ORDER BY 1 LIMIT 8")
dbGetQuery(con, "SELECT trim(a) AS country, COUNT(*) AS n_products
                 FROM (SELECT unnest(string_split(countries_en, ',')) AS a FROM fr_clean) GROUP BY 1 ORDER BY 2 DESC LIMIT 10")
#      result 7.14: grades a-plus to f; unknown in 123,116 products (31%), not-applicable in 8,922
#      result 7.15: 310,728 products (78%) seen only in France; world (7,206) is a placeholder, not a country;
#      4 products do not list France

# 7.14b environmental score: keep only real grades a-plus to f, and record why the others have no grade
dbExecute(con, "ALTER TABLE fr_clean ADD COLUMN IF NOT EXISTS environmental_score_status VARCHAR")
dbExecute(con, "UPDATE fr_clean SET environmental_score_status = CASE
                  WHEN environmental_score_grade IN ('a-plus','a','b','c','d','e','f') THEN 'graded'
                  WHEN environmental_score_grade = 'not-applicable'                    THEN 'not applicable'
                  ELSE 'unknown' END")
dbExecute(con, "UPDATE fr_clean SET environmental_score_grade = NULL
                WHERE environmental_score_grade NOT IN ('a-plus','a','b','c','d','e','f') OR environmental_score_grade IS NULL")
dbGetQuery(con, "SELECT environmental_score_status, COUNT(*) AS n_products FROM fr_clean GROUP BY 1 ORDER BY 2 DESC")

# 7.15b countries: look at the products that do not list France, then drop them
dbGetQuery(con, "SELECT code, product_name, countries_en FROM fr_clean WHERE countries_en NOT LIKE '%France%'")
dbExecute(con, "DELETE FROM fr_clean WHERE countries_en NOT LIKE '%France%'")

# sold_outside_france: true when any country other than France is listed, including the placeholder world
dbExecute(con, "ALTER TABLE fr_clean ADD COLUMN IF NOT EXISTS sold_outside_france BOOLEAN")
dbExecute(con, "UPDATE fr_clean SET sold_outside_france = len(string_split(countries_en, ',')) > 1")
dbGetQuery(con, "SELECT sold_outside_france, COUNT(*) AS n_products FROM fr_clean GROUP BY 1")
#      result: 267,374 graded, 123,770 unknown, 8,922 not applicable
#      the 4 products had a malformed tag en:france-spain (meaning France and Spain); they were dropped,
#      4 out of 400,066, noted as a known minor loss; 89,338 products are sold outside France

# 7.16 dates: when each product was added to Open Food Facts and when it was last edited, stored as text
dbGetQuery(con, "SELECT created_datetime, last_modified_datetime FROM fr_clean LIMIT 3")
dbGetQuery(con, "SELECT MIN(TRY_CAST(created_datetime AS TIMESTAMP)) AS first_created, MAX(TRY_CAST(created_datetime AS TIMESTAMP)) AS last_created,
                        MIN(TRY_CAST(last_modified_datetime AS TIMESTAMP)) AS first_modified, MAX(TRY_CAST(last_modified_datetime AS TIMESTAMP)) AS last_modified,
                        SUM(CASE WHEN TRY_CAST(created_datetime AS TIMESTAMP) IS NULL THEN 1 ELSE 0 END) AS created_not_a_date,
                        SUM(CASE WHEN TRY_CAST(last_modified_datetime AS TIMESTAMP) < TRY_CAST(created_datetime AS TIMESTAMP) THEN 1 ELSE 0 END) AS modified_before_created
                 FROM fr_clean")
dbGetQuery(con, "SELECT year(TRY_CAST(created_datetime AS TIMESTAMP)) AS year_added, COUNT(*) AS n_products FROM fr_clean GROUP BY 1 ORDER BY 1")
#      result: all valid dates from 2012-01-31 to 2026-11-10; no product modified before it was created;
#      most products were added in 2017 and 2018

# 7.16b dates: convert both columns from text to real timestamps
dbExecute(con, "ALTER TABLE fr_clean ALTER COLUMN created_datetime TYPE TIMESTAMP USING TRY_CAST(created_datetime AS TIMESTAMP)")
dbExecute(con, "ALTER TABLE fr_clean ALTER COLUMN last_modified_datetime TYPE TIMESTAMP USING TRY_CAST(last_modified_datetime AS TIMESTAMP)")
dbGetQuery(con, "SELECT any_value(typeof(created_datetime)) AS created_type, any_value(typeof(last_modified_datetime)) AS modified_type,
                        COUNT(created_datetime) AS n_created, COUNT(last_modified_datetime) AS n_modified FROM fr_clean")

# 7.17 data quality columns: creator (who added the product), completeness, scans, and quality error flags
dbGetQuery(con, "SELECT MIN(TRY_CAST(completeness AS DOUBLE)) AS min_completeness, MAX(TRY_CAST(completeness AS DOUBLE)) AS max_completeness,
                        COUNT(unique_scans_n) AS n_with_scans, MEDIAN(TRY_CAST(unique_scans_n AS INTEGER)) AS median_scans,
                        MAX(TRY_CAST(unique_scans_n AS INTEGER)) AS max_scans, COUNT(data_quality_errors_tags) AS n_with_errors
                 FROM fr_clean")
dbGetQuery(con, "SELECT trim(a) AS quality_error, COUNT(*) AS n_products
                 FROM (SELECT unnest(string_split(data_quality_errors_tags, ',')) AS a FROM fr_clean WHERE data_quality_errors_tags IS NOT NULL)
                 GROUP BY 1 ORDER BY 2 DESC LIMIT 10")
#      result 7.16b: both date columns are now timestamps, 400,062 filled
#      result 7.17: completeness runs 0.5 to 1 as expected; scans median 2, maximum 1,683;
#      14,792 products (3.7%) carry Open Food Facts quality flags, mostly energy values that do not match the other nutrients

# 7.17 energy check: calories computed from the label versus printed calories (run before 7.17b, nothing changed)
#      result: 366,779 products checkable; 10,785 (2.9%) differ by more than 20% and 20 kcal; Open Food Facts flags 6,584,
#      5,584 flagged by both; some differences are real errors (kJ typed as kcal, 0 kcal), some legitimate (polyol sweets)

# 7.17b data quality: numbers as numbers, plus two yes or no flags the tool can use to leave doubtful products out
dbExecute(con, "ALTER TABLE fr_clean ALTER COLUMN completeness TYPE DOUBLE USING TRY_CAST(completeness AS DOUBLE)")
dbExecute(con, "ALTER TABLE fr_clean ALTER COLUMN unique_scans_n TYPE INTEGER USING TRY_CAST(unique_scans_n AS INTEGER)")

# has_quality_flag: Open Food Facts itself detected at least one problem in the record
dbExecute(con, "ALTER TABLE fr_clean ADD COLUMN IF NOT EXISTS has_quality_flag BOOLEAN")
dbExecute(con, "UPDATE fr_clean SET has_quality_flag = data_quality_errors_tags IS NOT NULL AND trim(data_quality_errors_tags) <> ''")

# energy_mismatch: printed calories differ from calories computed from the label by more than 20% and more than 20 kcal
#   computed kcal = fat x 9 + carbohydrates x 4 + proteins x 4 + fiber x 2 + alcohol x 7
#   products that cannot be checked (a value missing) stay false; the printed values are kept as they are
dbExecute(con, "ALTER TABLE fr_clean ADD COLUMN IF NOT EXISTS energy_mismatch BOOLEAN")
dbExecute(con, 'UPDATE fr_clean SET energy_mismatch = COALESCE(
                  abs("energy-kcal_100g" - (9*fat_100g + 4*carbohydrates_100g + 4*proteins_100g
                                            + 2*COALESCE(fiber_100g, 0) + 7*COALESCE(alcohol_100g, 0)))
                  > greatest(20, 0.2*(9*fat_100g + 4*carbohydrates_100g + 4*proteins_100g
                                      + 2*COALESCE(fiber_100g, 0) + 7*COALESCE(alcohol_100g, 0))), false)')
dbGetQuery(con, "SELECT SUM(CASE WHEN has_quality_flag THEN 1 ELSE 0 END) AS n_quality_flag,
                        SUM(CASE WHEN energy_mismatch THEN 1 ELSE 0 END) AS n_energy_mismatch,
                        SUM(CASE WHEN has_quality_flag OR energy_mismatch THEN 1 ELSE 0 END) AS n_either,
                        COUNT(*) AS n_total FROM fr_clean")
#      result: 14,792 with an Open Food Facts quality flag, 10,785 with an energy mismatch, 19,719 with either

#---------------------------------------SECTION 8: EXPORT THE CLEAN TABLE

# 8.1 save the final clean table as parquet in the project folder, readable by any DuckDB or R version
dbExecute(con, sprintf("COPY fr_clean TO '%s' (FORMAT parquet)", file.path(dir, "fr_clean_final.parquet")))
dbGetQuery(con, "SELECT COUNT(*) AS n_products, COUNT(DISTINCT code) AS n_unique_codes FROM fr_clean")
length(dbGetQuery(con, "DESCRIBE fr_clean")$column_name)   # number of columns in the final table
#     result: 400,062 products, all with unique barcodes, 59 columns, saved as fr_clean_final.parquet

# 8.2 to load the final table back into RStudio
# con <- dbConnect(duckdb(dbdir = file.path(dir, "work.duckdb")))
# dbExecute(con, sprintf("CREATE OR REPLACE TABLE fr_final AS SELECT * FROM read_parquet('%s')", file.path(dir, "fr_clean_final.parquet")))
#---------------------------------------SECTION 9: FINAL TABLE FOR THE AI TOOL

# 9.1 build products: only the clean columns, renamed in plain english, with proper number types
#     the raw text columns (brands, allergens_en, labels_en, packaging_en, creator and others) stay in fr_clean only
dbExecute(con, '
CREATE OR REPLACE TABLE products AS
SELECT code, product_name, brand_owner, brand_range,
       quantity_value, quantity_type,
       pnns_groups_1                         AS food_group,
       pnns_groups_2                         AS food_subgroup,
       category_detail                       AS category,
       categories_en                         AS categories_list,
       nutriscore_grade,
       TRY_CAST(nutriscore_score AS INTEGER) AS nutriscore_score,
       nutriscore_status,
       TRY_CAST(nova_group AS INTEGER)       AS nova_group,
       TRY_CAST(additives_n AS INTEGER)      AS additives_count,
       additives_en                          AS additives_list,
       "energy-kcal_100g"                    AS energy_kcal,
       fat_100g                              AS fat_g,
       "saturated-fat_100g"                  AS saturated_fat_g,
       carbohydrates_100g                    AS carbohydrates_g,
       sugars_100g                           AS sugars_g,
       fiber_100g                            AS fiber_g,
       proteins_100g                         AS proteins_g,
       salt_100g                             AS salt_g,
       alcohol_100g                          AS alcohol_g,
       allergens_clean                       AS allergens,
       environmental_score_grade             AS ecoscore_grade,
       environmental_score_status            AS ecoscore_status,
       is_organic, is_vegan, is_vegetarian, is_fair_trade, no_gluten, no_lactose, no_palm_oil, no_added_sugar, made_in_france,
       pack_plastic, pack_glass, pack_paper_cardboard, pack_metal, is_frozen,
       countries_en                          AS countries,
       sold_outside_france,
       created_datetime                      AS added_on,
       last_modified_datetime                AS last_edited_on,
       unique_scans_n                        AS scans,
       completeness, has_quality_flag, energy_mismatch
FROM fr_clean')

# 9.2 check and save as parquet for the tests and, later, the website
dbGetQuery(con, "SELECT COUNT(*) AS n_products, COUNT(DISTINCT code) AS n_unique FROM products")
length(dbGetQuery(con, "DESCRIBE products")$column_name)   # number of columns the AI sees
dbExecute(con, sprintf("COPY products TO '%s' (FORMAT parquet, COMPRESSION zstd)", file.path(dir, "products.parquet")))
#     result: products has 400,062 rows and 50 columns; saved as products.parquet (29 MB)
