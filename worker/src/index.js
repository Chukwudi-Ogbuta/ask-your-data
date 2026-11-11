// Ask Your Data — the middleman between the website and the AI (Groq).
// What it does, in order:
//   1. accepts a question from the website (and, for a second chance, the AI's previous answer plus what went wrong)
//   2. sends it to the AI with the instructions in schema_for_ai.md, using the secret Groq key
//   3. if a model has hit its daily limit, tries the next model in line
//   4. checks the SQL the AI wrote is safe (read-only, products table only) before sending it back
// The visitor's browser then runs the SQL on the data itself (DuckDB in the browser).

import SCHEMA from "../../schema_for_ai.md";   // the AI instructions, same file used in all the tests

// models in order of preference: best tested first, then the backups
const MODELS = [
  { id: "qwen/qwen3.8-27b", effort: "medium" },
  { id: "openai/gpt-oss-120b", effort: "medium" },
  { id: "openai/gpt-oss-20b", effort: "medium" },
];
const MAX_QUESTION_LENGTH = 300;   // longer questions are refused, to keep costs and abuse down

export default {
  async fetch(request, env) {
    const cors = corsHeaders(request, env);
    // browsers first send an OPTIONS "may I?" request before the real one; answer it
    if (request.method === "OPTIONS") return new Response(null, { headers: cors });
    if (request.method !== "POST") return reply({ error: "Send a POST request." }, 405, cors);
    if (!cors["Access-Control-Allow-Origin"]) return reply({ error: "This website is not allowed." }, 403, cors);

    // 1. read and check the question
    let body;
    try { body = await request.json(); } catch { return reply({ error: "Body must be JSON." }, 400, cors); }
    const question = String(body.question || "").trim();
    if (!question) return reply({ error: "Empty question." }, 400, cors);
    if (question.length > MAX_QUESTION_LENGTH) return reply({ error: `Questions are limited to ${MAX_QUESTION_LENGTH} characters.` }, 400, cors);

    // the conversation sent to the AI: instructions, the question, and (second chance only) its previous try + the problem
    const messages = [{ role: "system", content: SCHEMA }, { role: "user", content: question }];
    if (body.previous && body.problem) {
      messages.push({ role: "assistant", content: JSON.stringify(body.previous).slice(0, 4000) });
      messages.push({ role: "user", content: String(body.problem).slice(0, 800) + " Correct the query. Return the same JSON format only." });
    }

    // 2–3. ask the models in order; move on when one is at its limit or failing
    for (const m of MODELS) {
      const res = await fetch("https://api.groq.com/openai/v1/chat/completions", {
        method: "POST",
        headers: { "Authorization": `Bearer ${env.GROQ_KEY}`, "Content-Type": "application/json" },
        body: JSON.stringify({ model: m.id, temperature: 0, reasoning_effort: m.effort,
                               response_format: { type: "json_object" }, messages }),
      });
      if (res.status === 429 || res.status >= 500) continue;   // limit reached or Groq trouble: next model
      if (!res.ok) return reply({ error: `AI service error (${res.status}).` }, 502, cors);

      const data = await res.json();
      let ans;
      try { ans = JSON.parse(data.choices[0].message.content); } catch { continue; }   // unreadable reply: next model

      // 4. safety check on the SQL before it goes back to the browser
      const sql = String(ans.sql || "");
      if (ans.status === "ok") {
        const verdict = checkSql(sql);
        if (verdict !== "ok") return reply({ status: "blocked", reason: verdict, model: m.id }, 200, cors);
      }
      return reply({ status: ans.status, sql, assumptions: ans.assumptions || "",
                     clarification: ans.clarification || "", model: m.id }, 200, cors);
    }
    // every model is at its daily limit
    return reply({ status: "limit", error: "Daily limit reached. Try the suggested questions, or come back tomorrow." }, 503, cors);
  },
};

// Safety check: one read-only SELECT on the products table, no file or system functions.
// Same rules as check_sql() in eval_groq.R.
function checkSql(sql) {
  let s = sql.toLowerCase();
  if (!/^\s*(select|with)\b/.test(s)) return "not a select";
  if (/;\s*\S/.test(s)) return "more than one statement";
  if (/\b(insert|update|delete|drop|create|alter|attach|detach|copy|pragma|install|load|export|import|call|set|truncate)\b/.test(s)) return "forbidden keyword";
  if (/read_(csv|parquet|json|text|blob)|glob\(|getenv|duckdb_|information_schema|sqlite_|https?:/.test(s)) return "forbidden function";
  s = s.replace(/\b(extract|trim|substring)\s*\([^()]*\)/g, "x");   // FROM inside these is not a table
  const tables = [...s.matchAll(/\b(from|join)\s+([a-z_][a-z0-9_]*)/g)].map(x => x[2]);
  const ctes = [...s.matchAll(/([a-z_][a-z0-9_]*)\s+as\s*\(/g)].map(x => x[1]);
  const bad = tables.filter(t => !["products", "unnest", "range", ...ctes].includes(t));
  return bad.length ? "other table: " + [...new Set(bad)].join(" ") : "ok";
}

// Only the allowed websites get the header that lets their browser read the reply
function corsHeaders(request, env) {
  const origin = request.headers.get("Origin") || "";
  const allowed = (env.ALLOWED_ORIGINS || "").split(",").map(x => x.trim());
  const h = { "Access-Control-Allow-Methods": "POST, OPTIONS", "Access-Control-Allow-Headers": "Content-Type" };
  if (allowed.includes(origin)) h["Access-Control-Allow-Origin"] = origin;
  return h;
}

function reply(obj, status, cors) {
  return new Response(JSON.stringify(obj), { status, headers: { ...cors, "Content-Type": "application/json" } });
}
