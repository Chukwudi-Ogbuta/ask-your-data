# Ask Your Data

Ask a question in plain English or French about 400,062 packaged foods sold in France. An AI writes the SQL query, the query is checked three ways, and it runs on the data inside your browser. Every answer can be flipped to show the exact query behind it.

**Live tool:** [chukwudi-ogbuta.github.io/ask-your-data/web](https://chukwudi-ogbuta.github.io/ask-your-data/web/)

**Author:** Chukwudi Ogbuta

---

## How it works

```
Visitor's question
   → Cloudflare Worker (holds the API key, tries Qwen → GPT-OSS-120B → GPT-OSS-20B)
   → AI writes a DuckDB SQL query, following schema_for_ai.md
   → Check 1, safety: read-only, one SELECT, products table only
   → Check 2, values: every food group, sub-group and brand named in the query exists in the data
   → Check 3, runs cleanly: DuckDB in the browser runs it on the data file
   → If any check fails, or the answer is empty or "unknown", the AI gets one second chance
   → Answer card: plain answer on the front, the query and checks on the back
```

Prepared suggestion questions skip the AI entirely: their SQL was written and checked in advance.

## The data

Source: the full Open Food Facts export (about 1.5 GB). Steps, all in `open-food.R`:

- Kept products sold in France with a record at least half complete, a brand, a valid barcode and a name: **400,062 products**.
- Cleaned brands: normalised spelling, split multi-brand entries, fixed near-duplicates by fuzzy matching (Jaro-Winkler), and linked brands to their owning company (e.g. Milbona → Lidl).
- Converted pack sizes to grams or millilitres, with checks for impossible values.
- Mapped allergens to the 14 official EU allergens using the Open Food Facts dictionary.
- Removed impossible nutrient values, and flagged products whose printed calories don't match their nutrients.
- Turned pack claims (organic, vegan, palm-oil-free…) and packaging into yes/no columns.

The result is `products.parquet` (50 columns, 29 MB).

## Testing

The AI was tested on **1,004 questions**: counts, filters, brands, allergens, nutrients, scores, rankings, French questions, typos, unclear questions, questions the data can't answer, and attempts to change or delete data. Each correct answer was written and checked by hand, and the AI's result was compared with it.

- **95.4% correct on the first full run** (958 of 1,004, Qwen model).
- The errors found were then fixed (rules in `schema_for_ai.md`, plus a value check and second-chance step) and every failed question was retested.

Files: `question_bank_v2.csv` (questions and correct SQL), `eval_groq.R` (test script), `eval_runs/` (results).

## Safety rules worth knowing

The data only records what is printed on the pack, so the tool never reads a missing value as its opposite:
- A missing allergen list means **unknown**, never allergen-free. Allergen answers always carry a reminder to check the label.
- "Palm-oil-free" and similar claims can't be turned around into "contains palm oil".
- "Nuts" in everyday language includes peanuts.

## Repository map

| Path | What it is |
|---|---|
| `open-food.R` | Data cleaning, step by step, with comments |
| `products.parquet` | The cleaned data (see licence below) |
| `schema_for_ai.md` | The instructions the AI follows |
| `question_bank_v1.csv`, `question_bank_v2.csv` | Test questions with their correct SQL |
| `eval_groq.R`, `eval_runs/` | Test script and results |
| `worker/` | Cloudflare Worker: model fallback, SQL safety check, problem reports |
| `web/` | The tool page (DuckDB-WASM in the browser) |

## Licence and attribution

Data from **Open Food Facts** (https://world.openfoodfacts.org), made available under the Open Database License (ODbL). See `LICENSE-DATA.md`.
