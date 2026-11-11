// Ask Your Data — the tool page, in a chat layout.
// Flow for a typed question:
//   1. send it to the Cloudflare Worker, which asks the AI and checks the SQL is safe
//   2. value check here: every group, sub-group and brand named in the SQL must exist in the data
//   3. run the SQL on the data, inside the visitor's browser (DuckDB-WASM)
//   4. if something is wrong (crash, unknown top answer, missing value), give the AI one second chance
//   5. show the answer as a chat bubble (big number, bar chart or table), the checks, and follow-up suggestions
// Suggestions skip the AI: their SQL was written and checked in advance, so they cost nothing.

import * as duckdb from "https://cdn.jsdelivr.net/npm/@duckdb/duckdb-wasm@1.29.0/+esm";

// ---------- settings ----------
const WORKER_URL = "https://ask-your-data-api.chukwudi-ogbuta.workers.dev";
const DATA_URL = new URL("../products.parquet", location.href).href;   // where the data file is served from
const $ = (id) => document.getElementById(id);

// ---------- text in both languages ----------
const T = {
  en: {
    noRows: "No products match that.", allergyNote: "⚠ For allergies, always check the label on the pack. This data comes from volunteers and can be incomplete.",
    title: "Ask your data", by: "A project by", tagline: "Turns plain-language questions into SQL", headline: "Turn plain-language questions into SQL",
    secHow: "How it works", how1: "You ask in plain English or French.", how2: "The AI writes an SQL query, and it is checked three ways.", how3: "It runs on the data in your browser. Tap See query on any answer to check it matches your question.", secData: "The data", secAsk: "Ask about", about: "About",
    inIt: "What's in it", inItText: "400,062 packaged foods sold in France, from their labels: brand, food type, Nutri-Score, processing, allergens, nutrients, and claims like organic or vegan.",
    notIn: "What's not", notInText: "Prices, sales, stores, stock, expiry dates or reviews.",
    from: "Source", fromText: "Open Food Facts, a free database built by volunteers. Cleaned and checked by me; some details can still be missing.",
    sAcc: "right first time", sTests: "test questions", foot: "Data from Open Food Facts (ODbL).", code: "Cleaned data and code",
    ask: "Ask", guessLabel: "Guess first", placeholder: "Ask a question about French food…",
    mistakes: "AI can make mistakes. Flip any answer to see the query behind it.",
    hello: "Hi. Ask me anything about 400,062 packaged foods sold in France, in plain English or French. I translate your question into an SQL query, check it and run it. Tap See query on any answer to compare the query with what you asked.",
    tryThese: "Try one of these:", alsoAsk: "You could also ask:", topicIntro: "Here are some questions about {x}:",
    loading: "Loading the products into your browser…", thinking: "Writing the query…", running: "Running it on the data…", retry: "Fixing the query…",
    report: "Report a problem", reportAsk: "Send this answer for review? The question, answer and query are attached.", reportPh: "Anything to add? (optional)", reportSend: "Send report", reportCancel: "Cancel", reportThanks: "Thanks, report sent ✓", reportFail: "Couldn't send the report. Please try again.",
    fAnswer: "Answer", fQuery: "See query", backTitle: "The query behind this answer",
    cWritten: "Written by the AI ({m})", cChip: "Prepared question: query written and checked in advance",
    cSafe: "Safe: read-only, one table", cValues: "Every name used exists in the data",
    cRetry: "Second chance used: the first query had a problem and was corrected", cRan: "Ran on {n} products in {ms} ms",
    first: "{a} comes first.", tie: "{a} and {b} tie at the top.", highest: "{a} has the highest value ({v}).", lowest: "{a} has the best score ({v}, lower is better).", unknown: "unknown (not recorded)", rows: "Showing {k} of {n} rows.",
    notInData: "That isn't in this data. It has no prices, sales, stores, stock or reviews, only what's printed on the packs.",
    offTopic: "I can only read this food data and answer questions about it. I can't change or delete anything, and I can't help with other topics.", blocked: "The safety check blocked that query, so nothing was run.",
    limit: "The free AI allowance is used up for now. Meanwhile, these questions still answer instantly:", limitIn: "The free AI allowance is used up for now. It frees up again in about {m} minutes. Meanwhile, these questions still answer instantly:",
    error: "Something went wrong. Please try again.", needGuess: "Type your guess first (next to Guess first), then ask.",
    guessRes: "Your guess: {g}. Actual: {a}. ", close: "Very close!", off: "Off by {p}%.", noGuess: "Guessing works for single-number answers.",
    guessHit: "Spot on!", guessNear: "Close: it's number {k}. {a} is first.", guessIn: "It's number {k}. The top one is {a}.", guessMiss: "Not this time: the top one is {a}.", guessPh: "a number or a name", yourGuess: "Your guess: {g}. ",
    topics: { health: "Health scores", brands: "Brands", allergens: "Allergens", saltsugar: "Salt and sugar", processing: "Processing", claims: "Organic, vegan and more" },
  },
  fr: {
    noRows: "Aucun produit ne correspond.", allergyNote: "⚠ En cas d'allergie, vérifiez toujours l'étiquette sur l'emballage. Ces données viennent de bénévoles et peuvent être incomplètes.",
    title: "Interrogez les données", by: "Un projet de", tagline: "Transforme vos questions en requêtes SQL", headline: "Transformez vos questions en requêtes SQL",
    secHow: "Comment ça marche", how1: "Vous posez votre question en français ou en anglais.", how2: "L'IA écrit une requête SQL, vérifiée de trois façons.", how3: "Elle s'exécute sur les données dans votre navigateur. Touchez Voir la requête pour vérifier qu'elle correspond à votre question.", secData: "Les données", secAsk: "Thèmes", about: "À propos",
    inIt: "Ce qu'elles contiennent", inItText: "400 062 produits emballés vendus en France, d'après leurs étiquettes : marque, type d'aliment, Nutri-Score, transformation, allergènes, nutriments et mentions comme bio ou végan.",
    notIn: "Ce qu'elles ne contiennent pas", notInText: "Prix, ventes, magasins, stocks, dates de péremption ou avis.",
    from: "Source", fromText: "Open Food Facts, une base gratuite construite par des bénévoles. Nettoyée et vérifiée par moi ; certains détails peuvent manquer.",
    sAcc: "justes au premier essai", sTests: "questions de test", foot: "Données Open Food Facts (ODbL).", code: "Données nettoyées et code",
    ask: "Demander", guessLabel: "Deviner d'abord", placeholder: "Posez une question sur l'alimentation en France…",
    mistakes: "L'IA peut se tromper. Retournez une réponse pour voir la requête derrière.",
    hello: "Bonjour. Posez-moi n'importe quelle question sur 400 062 produits emballés vendus en France, en français ou en anglais. Je traduis votre question en requête SQL, je la vérifie puis je l'exécute. Touchez Voir la requête sur une réponse pour la comparer à votre question.",
    tryThese: "Essayez par exemple :", alsoAsk: "Vous pourriez aussi demander :", topicIntro: "Quelques questions sur le thème {x} :",
    loading: "Chargement des produits dans votre navigateur…", thinking: "Écriture de la requête…", running: "Exécution sur les données…", retry: "Correction de la requête…",
    report: "Signaler un problème", reportAsk: "Envoyer cette réponse pour vérification ? La question, la réponse et la requête sont jointes.", reportPh: "Un commentaire ? (facultatif)", reportSend: "Envoyer", reportCancel: "Annuler", reportThanks: "Merci, signalement envoyé ✓", reportFail: "Le signalement n'a pas pu être envoyé. Réessayez.",
    fAnswer: "Réponse", fQuery: "Voir la requête", backTitle: "La requête derrière cette réponse",
    cWritten: "Écrite par l'IA ({m})", cChip: "Question préparée : requête écrite et vérifiée à l'avance",
    cSafe: "Sûre : lecture seule, une seule table", cValues: "Chaque nom utilisé existe dans les données",
    cRetry: "Seconde chance utilisée : la première requête avait un problème et a été corrigée", cRan: "Exécutée sur {n} produits en {ms} ms",
    first: "{a} arrive en tête.", tie: "{a} et {b} sont à égalité en tête.", highest: "{a} a la valeur la plus élevée ({v}).", lowest: "{a} a le meilleur score ({v}, plus bas = mieux).", unknown: "inconnu (non renseigné)", rows: "{k} lignes affichées sur {n}.",
    notInData: "Ce n'est pas dans ces données : pas de prix, ventes, magasins, stocks ni avis, seulement ce qui figure sur les emballages.",
    offTopic: "Je peux seulement lire ces données alimentaires et répondre à des questions dessus. Je ne peux rien modifier ni supprimer, ni aider sur d'autres sujets.", blocked: "Le contrôle de sécurité a bloqué cette requête : rien n'a été exécuté.",
    limit: "Le quota gratuit d'IA est épuisé pour l'instant. En attendant, ces questions répondent tout de suite :", limitIn: "Le quota gratuit d'IA est épuisé pour l'instant. Il se libère dans environ {m} minutes. En attendant, ces questions répondent tout de suite :",
    error: "Un problème est survenu. Veuillez réessayer.", needGuess: "Saisissez d'abord votre estimation (à côté de Deviner d'abord), puis demandez.",
    guessRes: "Votre estimation : {g}. Réel : {a}. ", close: "Très proche !", off: "Écart de {p} %.", noGuess: "L'estimation fonctionne pour les réponses à un seul nombre.",
    guessHit: "Bien vu !", guessNear: "Presque : c'est le numéro {k}. {a} est premier.", guessIn: "C'est le numéro {k}. Le premier est {a}.", guessMiss: "Pas cette fois : le premier est {a}.", guessPh: "un nombre ou un nom", yourGuess: "Votre estimation : {g}. ",
    topics: { health: "Scores santé", brands: "Marques", allergens: "Allergènes", saltsugar: "Sel et sucre", processing: "Transformation", claims: "Bio, végan et autres" },
  },
};
let lang = "en";
const t = (k, vars = {}) => T[lang][k].replace(/\{(\w+)\}/g, (_, v) => vars[v]);

// ---------- library of prepared questions (SQL checked in advance; tags pick the follow-ups) ----------
const LIB = [
  { id: "h1", tags: ["health", "cheese"], en: "How many cheeses have a Nutri-Score A?", fr: "Combien de fromages ont un Nutri-Score A ?",
    sql: "SELECT COUNT(*) AS cheeses_with_nutri_score_a FROM products WHERE food_subgroup = 'Cheese' AND nutriscore_grade = 'a'" },
  { id: "h2", tags: ["health"], en: "How many products per Nutri-Score grade?", fr: "Combien de produits par note Nutri-Score ?",
    sql: "SELECT upper(nutriscore_grade) AS grade, COUNT(*) AS products FROM products WHERE nutriscore_grade IS NOT NULL GROUP BY 1 ORDER BY 1" },
  { id: "h3", tags: ["health", "cereals"], en: "What share of breakfast cereals have a Nutri-Score A?", fr: "Quelle part des céréales du petit-déjeuner a un Nutri-Score A ?",
    sql: "SELECT ROUND(100.0 * AVG(CASE WHEN nutriscore_grade = 'a' THEN 1 ELSE 0 END), 1) AS percent_with_nutri_score_a FROM products WHERE food_subgroup = 'Breakfast cereals' AND nutriscore_grade IS NOT NULL" },
  { id: "h4", tags: ["health"], en: "Which food types have the highest share of Nutri-Score E?", fr: "Quels types d'aliments ont la plus forte part de Nutri-Score E ?",
    sql: "SELECT food_subgroup, ROUND(100.0 * AVG(CASE WHEN nutriscore_grade = 'e' THEN 1 ELSE 0 END), 1) AS percent_grade_e FROM products WHERE food_subgroup IS NOT NULL AND nutriscore_grade IS NOT NULL GROUP BY 1 ORDER BY 2 DESC LIMIT 5" },
  { id: "p1", tags: ["processing", "health"], en: "What share of products are ultra-processed?", fr: "Quelle part des produits est ultra-transformée ?",
    sql: "SELECT ROUND(100.0 * AVG(CASE WHEN nova_group = 4 THEN 1 ELSE 0 END), 1) AS percent_ultra_processed FROM products WHERE nova_group IS NOT NULL" },
  { id: "p2", tags: ["processing"], en: "Which food types are the most ultra-processed?", fr: "Quels types d'aliments sont les plus ultra-transformés ?",
    sql: "SELECT food_subgroup, ROUND(100.0 * AVG(CASE WHEN nova_group = 4 THEN 1 ELSE 0 END), 1) AS percent_ultra_processed FROM products WHERE food_subgroup IS NOT NULL AND nova_group IS NOT NULL GROUP BY 1 ORDER BY 2 DESC LIMIT 5" },
  { id: "p3", tags: ["processing"], en: "What are the most common additives?", fr: "Quels sont les additifs les plus courants ?",
    sql: "SELECT a AS additive, COUNT(*) AS products FROM (SELECT unnest(string_split(additives_list, ',')) AS a FROM products WHERE additives_list IS NOT NULL) GROUP BY 1 ORDER BY 2 DESC LIMIT 5" },
  { id: "b1", tags: ["brands", "organic"], en: "Which brands have the most organic products?", fr: "Quelles marques ont le plus de produits bio ?",
    sql: "SELECT brand_owner, COUNT(*) AS organic_products FROM products WHERE is_organic GROUP BY 1 ORDER BY 2 DESC LIMIT 5" },
  { id: "b2", tags: ["brands"], en: "Which brand owners have the most products?", fr: "Quels propriétaires de marques ont le plus de produits ?",
    sql: "SELECT brand_owner, COUNT(*) AS products FROM products GROUP BY 1 ORDER BY 2 DESC LIMIT 5" },
  { id: "b3", tags: ["brands", "chocolate"], en: "Which brands make the most chocolate products?", fr: "Quelles marques font le plus de produits chocolatés ?",
    sql: "SELECT brand_range AS brand, COUNT(*) AS chocolate_products FROM products WHERE food_subgroup = 'Chocolate products' GROUP BY 1 ORDER BY 2 DESC LIMIT 5" },
  { id: "b4", tags: ["brands", "salt", "sauces"], en: "Saltiest sauce brands", fr: "Marques de sauces les plus salées",
    sql: "SELECT brand_owner, ROUND(AVG(salt_g), 2) AS avg_salt_g_per_100g FROM products WHERE food_subgroup = 'Dressings and sauces' AND salt_g IS NOT NULL GROUP BY 1 HAVING COUNT(*) >= 30 ORDER BY 2 DESC LIMIT 5" },
  { id: "a1", tags: ["allergens"], en: "Which allergens appear most often?", fr: "Quels allergènes apparaissent le plus ?",
    sql: "SELECT a AS allergen, COUNT(*) AS products FROM (SELECT unnest(string_split(allergens, ',')) AS a FROM products WHERE allergens IS NOT NULL) GROUP BY 1 ORDER BY 2 DESC LIMIT 5" },
  { id: "a2", tags: ["allergens"], en: "How many products contain peanuts?", fr: "Combien de produits contiennent des arachides ?",
    sql: "SELECT COUNT(*) AS products_with_peanuts FROM products WHERE list_contains(string_split(allergens, ','), 'peanuts')" },
  { id: "a3", tags: ["allergens"], en: "How many biscuits and cakes contain milk?", fr: "Combien de biscuits et gâteaux contiennent du lait ?",
    sql: "SELECT COUNT(*) AS biscuits_and_cakes_with_milk FROM products WHERE food_subgroup = 'Biscuits and cakes' AND list_contains(string_split(allergens, ','), 'milk')" },
  { id: "a4", tags: ["allergens"], en: "What share of products contain gluten?", fr: "Quelle part des produits contient du gluten ?",
    sql: "SELECT ROUND(100.0 * AVG(CASE WHEN list_contains(string_split(allergens, ','), 'gluten') THEN 1 ELSE 0 END), 1) AS percent_with_gluten FROM products WHERE allergens IS NOT NULL" },
  { id: "n1", tags: ["nutrition", "salt"], en: "Which food types are the saltiest?", fr: "Quels types d'aliments sont les plus salés ?",
    sql: "SELECT food_subgroup, ROUND(AVG(salt_g), 2) AS avg_salt_g_per_100g FROM products WHERE food_subgroup IS NOT NULL GROUP BY 1 ORDER BY 2 DESC LIMIT 5" },
  { id: "n2", tags: ["salt", "cheese"], en: "Average salt in cheeses", fr: "Sel moyen dans les fromages",
    sql: "SELECT ROUND(AVG(salt_g), 2) AS avg_salt_g_per_100g FROM products WHERE food_subgroup = 'Cheese'" },
  { id: "n3", tags: ["salt"], en: "Products over 2 g of salt per 100 g", fr: "Produits à plus de 2 g de sel pour 100 g",
    sql: "SELECT COUNT(*) AS products_over_2g_salt FROM products WHERE salt_g > 2" },
  { id: "n4", tags: ["nutrition", "sugar"], en: "Which food types have the most sugar?", fr: "Quels types d'aliments sont les plus sucrés ?",
    sql: "SELECT food_subgroup, ROUND(AVG(sugars_g), 1) AS avg_sugar_g_per_100g FROM products WHERE food_subgroup IS NOT NULL GROUP BY 1 ORDER BY 2 DESC LIMIT 5" },
  { id: "n5", tags: ["sugar", "cereals"], en: "Average sugar in breakfast cereals", fr: "Sucre moyen des céréales du petit-déjeuner",
    sql: "SELECT ROUND(AVG(sugars_g), 1) AS avg_sugar_g_per_100g FROM products WHERE food_subgroup = 'Breakfast cereals'" },
  { id: "n6", tags: ["nutrition", "protein"], en: "Which food types have the most protein?", fr: "Quels types d'aliments ont le plus de protéines ?",
    sql: "SELECT food_subgroup, ROUND(AVG(proteins_g), 1) AS avg_protein_g_per_100g FROM products WHERE food_subgroup IS NOT NULL GROUP BY 1 ORDER BY 2 DESC LIMIT 5" },
  { id: "c1", tags: ["organic", "claims"], en: "How many organic products are there?", fr: "Combien de produits bio y a-t-il ?",
    sql: "SELECT COUNT(*) AS organic_products FROM products WHERE is_organic" },
  { id: "c2", tags: ["claims", "vegan"], en: "Which food types have the most vegan products?", fr: "Quels types d'aliments ont le plus de produits végans ?",
    sql: "SELECT food_subgroup, COUNT(*) AS vegan_products FROM products WHERE is_vegan AND food_subgroup IS NOT NULL GROUP BY 1 ORDER BY 2 DESC LIMIT 5" },
  { id: "c3", tags: ["claims"], en: "How many products say made in France?", fr: "Combien de produits indiquent fabriqué en France ?",
    sql: "SELECT COUNT(*) AS made_in_france_products FROM products WHERE made_in_france" },
  { id: "k1", tags: ["packaging"], en: "What share of drinks come in plastic?", fr: "Quelle part des boissons est en plastique ?",
    sql: "SELECT ROUND(100.0 * AVG(CASE WHEN pack_plastic THEN 1 ELSE 0 END), 1) AS percent_in_plastic FROM products WHERE food_group = 'Beverages'" },
];
const STARTERS = [["health", "h1"], ["brands", "b1"], ["allergens", "a1"], ["saltsugar", "n1"]];
// side-panel topics: which library tags each one shows
const TOPICS = { health: ["health"], brands: ["brands"], allergens: ["allergens"], saltsugar: ["salt", "sugar"], processing: ["processing"], claims: ["claims", "organic", "vegan", "packaging"] };
const asked = new Set();
// short memory of the conversation, sent with each new question (the Worker keeps the last 6)
const history = [];
const remember = (role, content) => { history.push({ role, content }); if (history.length > 12) history.splice(0, history.length - 12); };

// topics of an answer, read from the SQL, so follow-ups stay on the same subject
function topicsOf(sql) {
  const s = sql.toLowerCase(), tags = [];
  const rules = [["salt", /salt_g/], ["sugar", /sugars_g/], ["protein", /proteins_g/], ["allergens", /allergens/],
    ["health", /nutriscore/], ["processing", /nova_group|additive/], ["brands", /brand_/], ["organic", /is_organic/],
    ["vegan", /is_vegan/], ["claims", /made_in_france|is_vegan|is_organic|no_/], ["packaging", /pack_/],
    ["cheese", /cheese/], ["chocolate", /chocolate/], ["cereals", /cereal/], ["sauces", /sauce/], ["nutrition", /_g\b/]];
  for (const [tag, re] of rules) if (re.test(s)) tags.push(tag);
  return tags;
}
function followUps(sql) {
  const tags = topicsOf(sql);
  const score = (q) => q.tags.filter(x => tags.includes(x)).length;
  const pool = LIB.filter(q => !asked.has(q.id)).sort((a, b) => score(b) - score(a) || Math.random() - 0.5);
  return pool.slice(0, 3);
}

// ---------- DuckDB in the browser ----------
let conn, TOTAL = 0, ready = false;
const known = { food_group: new Set(), food_subgroup: new Set(), brand: new Set(), brandTop: [] };

async function startDb() {
  // pick the DuckDB build that suits this browser, and run it in a background worker
  const bundle = await duckdb.selectBundle(duckdb.getJsDelivrBundles());
  const workerUrl = URL.createObjectURL(new Blob([`importScripts("${bundle.mainWorker}");`], { type: "text/javascript" }));
  const db = new duckdb.AsyncDuckDB(new duckdb.VoidLogger(), new Worker(workerUrl));
  await db.instantiate(bundle.mainModule, bundle.pthreadWorker);
  // big whole numbers (sums) and decimals come back as ordinary numbers, so they format and chart properly
  await db.open({ query: { castBigIntToDouble: true, castDecimalToDouble: true } });
  conn = await db.connect();
  // download the data file once and load it as a table, so every query after is fast
  const buf = new Uint8Array(await (await fetch(DATA_URL)).arrayBuffer());
  await db.registerFileBuffer("products.parquet", buf);
  await conn.query("CREATE TABLE products AS SELECT * FROM read_parquet('products.parquet')");
  TOTAL = Number((await rows("SELECT COUNT(*) AS n FROM products"))[0].n);
  // real values, for the value check
  for (const r of await rows("SELECT DISTINCT food_group AS v FROM products WHERE food_group IS NOT NULL")) known.food_group.add(r.v);
  for (const r of await rows("SELECT DISTINCT food_subgroup AS v FROM products WHERE food_subgroup IS NOT NULL")) known.food_subgroup.add(r.v);
  for (const r of await rows("SELECT DISTINCT brand_owner AS v FROM products UNION SELECT DISTINCT brand_range FROM products")) if (r.v) known.brand.add(r.v);
  known.brandTop = (await rows("SELECT brand_owner AS v FROM products GROUP BY 1 ORDER BY COUNT(*) DESC LIMIT 3000")).map(r => r.v);
}
// run SQL and return plain rows; big whole numbers from DuckDB (BigInt) become normal numbers
async function rows(sql) {
  const res = await conn.query(sql);
  return res.toArray().map(r => {
    const o = r.toJSON();
    for (const k in o) {
      if (typeof o[k] === "bigint") o[k] = Number(o[k]);
      else if (o[k] !== null && typeof o[k] === "object" && !(o[k] instanceof Date)) {   // any other number-like object
        const n = Number(String(o[k])); if (!isNaN(n)) o[k] = n;
      }
    }
    return o;
  });
}
async function runSql(sql) {
  const t0 = performance.now();
  try { const r = await rows(`SELECT * FROM (${sql.replace(/;\s*$/, "")}) AS t LIMIT 200`); return { rows: r, ms: Math.round(performance.now() - t0) }; }
  catch (e) { return { error: String(e.message || e).slice(0, 400) }; }
}
const textCols = (r) => r.length ? Object.keys(r[0]).filter(k => typeof r[0][k] !== "number") : [];

// ---------- value check (same rules as the test script) ----------
function quoted(s) { return [...s.matchAll(/'([^']*)'/g)].map(m => m[1]); }
function jaroWinkler(a, b) {
  if (a === b) return 1;
  const md = Math.max(0, Math.floor(Math.max(a.length, b.length) / 2) - 1), am = [], bm = [];
  let m = 0;
  for (let i = 0; i < a.length; i++) for (let j = Math.max(0, i - md); j < Math.min(b.length, i + md + 1); j++)
    if (!bm[j] && a[i] === b[j]) { am[i] = bm[j] = true; m++; break; }
  if (!m) return 0;
  let k = 0, tr = 0;
  for (let i = 0; i < a.length; i++) if (am[i]) { while (!bm[k]) k++; if (a[i] !== b[k]) tr++; k++; }
  const j = (m / a.length + m / b.length + (m - tr / 2) / m) / 3;
  let p = 0; while (p < 4 && a[p] === b[p]) p++;
  return j + p * 0.1 * (1 - j);
}
const nearest = (v, list) => [...list].sort((x, y) => jaroWinkler(v, y.toLowerCase()) - jaroWinkler(v, x.toLowerCase())).slice(0, 3);
function checkValues(sql) {
  const msgs = [];
  for (const col of ["food_subgroup", "food_group"]) {
    const re = new RegExp(`\\b${col}\\s*(=|<>|!=)\\s*'[^']*'|\\b${col}\\s+(not\\s+)?in\\s*\\([^)]*\\)`, "gi");
    for (const hit of sql.match(re) || []) for (const v of quoted(hit)) {
      if (known[col].has(v)) continue;
      const other = col === "food_group" ? "food_subgroup" : "food_group";
      msgs.push(known[other].has(v) ? `'${v}' is a ${other}, not a ${col}.`
        : `'${v}' is not a ${col}. Closest values: ${nearest(v.toLowerCase(), known[col]).map(x => `'${x}'`).join(", ")}.`);
    }
  }
  for (const hit of sql.match(/\bbrand_(owner|range)\s*(=|i?like)\s*'[^']*'/gi) || []) {
    const v = quoted(hit)[0].replace(/%/g, "").toLowerCase();
    const found = /like/i.test(hit) ? [...known.brand].some(b => b.includes(v)) : known.brand.has(v);
    if (!found) msgs.push(`No brand matches '${v}' (maybe a typo). Closest brands: ${nearest(v, known.brandTop).map(x => `'${x}'`).join(", ")}.`);
  }
  return [...new Set(msgs)].join(" ");
}

// ---------- chat bubbles ----------
const esc = (s) => String(s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const fmt = (v) => typeof v === "number" ? new Intl.NumberFormat(lang === "fr" ? "fr-FR" : "en-GB", { maximumFractionDigits: 2 }).format(v) : v;
const isPct = (c) => /pct|percent|share|pourcent/i.test(c);
const fmtCol = (c, v) => typeof v === "number" && isPct(c) ? fmt(v) + (lang === "fr" ? " %" : "%") : fmt(v);
const pretty = (c) => c.replace(/_/g, " ").replace(/\bavg\b/, lang === "fr" ? "moyenne" : "average").replace(/\bg per 100g\b/, "(g per 100 g)");
const scrollDown = () => $("thread").scrollTo({ top: $("thread").scrollHeight, behavior: "smooth" });
function add(el) { $("col").appendChild(el); scrollDown(); return el; }
function botSay(html, wide) { const d = document.createElement("div"); d.className = "bot" + (wide ? " wide" : ""); d.innerHTML = `<div class="say">${html}</div>`; return add(d); }
function typing(text) { const d = document.createElement("div"); d.className = "bot typing"; d.textContent = text; return add(d); }
function meSay(text) {   // your message: green bubble with the time and two ticks, like WhatsApp
  const d = document.createElement("div"); d.className = "me";
  const time = new Date().toLocaleTimeString(lang === "fr" ? "fr-FR" : "en-GB", { hour: "2-digit", minute: "2-digit" });
  d.innerHTML = `${esc(text)}<span class="meta">${time} ✓✓</span>`; return add(d);
}
function chipRow(items, label) {
  const row = document.createElement("div"); row.className = "chips";
  row.innerHTML = label ? `<div class="label">${esc(label)}</div>` : "";
  for (const q of items) { const b = document.createElement("button"); b.className = "chip"; b.textContent = q[lang]; b.onclick = () => submit(q[lang], q.free ? null : q); row.appendChild(b); }
  return add(row);
}
function greet() {
  $("col").innerHTML = "";
  const d = botSay(esc(t("hello")), true);
  d.insertAdjacentHTML("beforeend", `<div class="hint">${t("tryThese")}</div>`);
  for (const [topic, id] of STARTERS) {
    const q = LIB.find(x => x.id === id), b = document.createElement("button");
    b.className = "starter"; b.innerHTML = `<small>${esc(T[lang].topics[topic])}</small>${esc(q[lang])}`;
    b.onclick = () => submit(q[lang], q); d.appendChild(b);
  }
}
function renderTopics() {
  $("topics").innerHTML = "";
  for (const key of Object.keys(TOPICS)) {
    const b = document.createElement("button"); b.textContent = T[lang].topics[key];
    b.onclick = () => {
      $("side").classList.remove("open");
      const qs = LIB.filter(q => q.tags.some(x => TOPICS[key].includes(x)));
      chipRow(qs, t("topicIntro", { x: T[lang].topics[key].toLowerCase() }));
      setBusy(false);
    };
    $("topics").appendChild(b);
  }
}
// food types and allergens are stored in English; show them in the visitor's language
const SUB_FR = { "Biscuits and cakes": "Biscuits et gâteaux", "Sweets": "Confiseries", "One-dish meals": "Plats préparés", "Cereals": "Céréales",
  "Processed meat": "Charcuteries", "Dressings and sauces": "Sauces", "Cheese": "Fromages", "Meat": "Viandes", "Fish and seafood": "Poissons et fruits de mer",
  "Milk and yogurt": "Lait et yaourts", "Vegetables": "Légumes", "Sweetened beverages": "Boissons sucrées", "Chocolate products": "Produits chocolatés",
  "Alcoholic beverages": "Boissons alcoolisées", "Appetizers": "Apéritifs", "Bread": "Pains", "Fruits": "Fruits", "Teas and herbal teas and coffees": "Thés, tisanes et cafés",
  "Salty and fatty products": "Produits gras et salés", "Fats": "Matières grasses", "Dairy desserts": "Desserts lactés", "Ice cream": "Glaces",
  "Breakfast cereals": "Céréales du petit-déjeuner", "Fruit juices": "Jus de fruits", "Legumes": "Légumineuses", "Nuts": "Fruits à coque",
  "Artificially sweetened beverages": "Boissons édulcorées", "Dried fruits": "Fruits secs", "Pastries": "Viennoiseries", "Pizza pies and quiches": "Pizzas, tartes et quiches",
  "Potatoes": "Pommes de terre", "Unsweetened beverages": "Boissons non sucrées", "Soups": "Soupes", "Sandwiches": "Sandwichs",
  "Plant-based milk substitutes": "Boissons végétales", "Waters and flavored waters": "Eaux et eaux aromatisées", "Baby foods": "Aliments pour bébés",
  "Eggs": "Œufs", "Offals": "Abats", "Baby milks": "Laits infantiles", "Fruit nectars": "Nectars de fruits",
  "Sugary snacks": "Produits sucrés", "Fish Meat Eggs": "Viandes, poissons, œufs", "Cereals and potatoes": "Féculents", "Milk and dairy products": "Produits laitiers",
  "Beverages": "Boissons", "Composite foods": "Plats composés", "Fruits and vegetables": "Fruits et légumes", "Fat and sauces": "Matières grasses et sauces", "Salty snacks": "Snacks salés" };
const ALLERGENS = { milk: ["Milk", "Lait"], gluten: ["Gluten", "Gluten"], eggs: ["Eggs", "Œufs"], soybeans: ["Soy", "Soja"], nuts: ["Tree nuts", "Fruits à coque"],
  peanuts: ["Peanuts", "Arachides"], fish: ["Fish", "Poisson"], crustaceans: ["Crustaceans", "Crustacés"], molluscs: ["Molluscs", "Mollusques"], celery: ["Celery", "Céleri"],
  mustard: ["Mustard", "Moutarde"], "sesame seeds": ["Sesame", "Sésame"], "sulphur dioxide and sulphites": ["Sulphites", "Sulfites"], lupin: ["Lupin", "Lupin"] };
const NOVA = { 1: ["NOVA 1 – unprocessed", "NOVA 1 – brut"], 2: ["NOVA 2 – culinary ingredients", "NOVA 2 – ingrédients culinaires"],
  3: ["NOVA 3 – processed", "NOVA 3 – transformé"], 4: ["NOVA 4 – ultra-processed", "NOVA 4 – ultra-transformé"] };
function displayLabel(col, v) {
  if (v === null || v === undefined) return v;
  const L = lang === "fr" ? 1 : 0;
  if (typeof v === "boolean" || v === "true" || v === "false") {
    const yes = v === true || v === "true";
    return `${PLAIN[col] || pretty(col)}: ${yes ? (L ? "oui" : "yes") : (L ? "non" : "no")}`;
  }
  if (/nova/i.test(col) && NOVA[v]) return NOVA[v][L];
  if (ALLERGENS[v]) return ALLERGENS[v][L];
  if (lang === "fr" && SUB_FR[v]) return SUB_FR[v];
  if (isBrandCol(col)) return brandName(v);
  return v;
}

// brand names are stored lowercase without accents; show them the way people write them
const BRAND_NAMES = { "u": "Système U", "cote dor": "Côte d'Or", "nestle": "Nestlé", "intermarche": "Intermarché", "leclerc": "Leclerc",
  "lu": "LU", "la vie claire": "La Vie Claire", "leader price": "Leader Price", "fleury michon": "Fleury Michon", "bonne maman": "Bonne Maman",
  "haagen dazs": "Häagen-Dazs", "president": "Président", "coca cola": "Coca-Cola", "marks & spencer": "Marks & Spencer" };
const brandName = (v) => v == null ? v : BRAND_NAMES[v] || String(v).replace(/(^|[\s-])(\p{L})/gu, (m, a, b) => a + b.toUpperCase());
const isBrandCol = (c) => /^brand(_owner|_range)?$/.test(c);
// safety net: any database word left in the AI's note is turned into plain words
const PLAIN = { brand_owner: "brand owner", brand_range: "brand", food_subgroup: "food type", food_group: "food group",
  nutriscore_grade: "Nutri-Score", nutriscore_score: "Nutri-Score points", nova_group: "processing level", categories_list: "categories",
  energy_kcal: "calories", sugars_g: "sugar", salt_g: "salt", fat_g: "fat", proteins_g: "protein", fiber_g: "fibre", additives_count: "number of additives",
  is_organic: "organic label", is_vegan: "vegan label", made_in_france: "made-in-France label", energy_mismatch: "calorie check",
  quantity_value: "pack size", quantity_type: "pack size type", added_on: "date added", last_edited_on: "last edit date", ecoscore_grade: "Eco-Score",
  saturated_fat_g: "saturated fat", carbohydrates_g: "carbohydrates", alcohol_g: "alcohol", allergens: "allergens list", additives_list: "additives",
  no_palm_oil: "palm-oil-free label", no_gluten: "gluten-free label", no_lactose: "lactose-free label", no_added_sugar: "no-added-sugar label",
  is_vegetarian: "vegetarian label", is_fair_trade: "fair-trade label", is_frozen: "frozen", sold_outside_france: "sold outside France", category: "category" };
const plainNote = (txt) => String(txt)
  .replace(/\s*\(([a-z]+(?:_[a-z0-9]+)+)\)/g, (m, w) => PLAIN[w] ? "" : m)      // "(brand_owner)" right after its plain meaning: drop it
  .replace(/\b([a-z]+(?:_[a-z0-9]+)+)\b/g, (m, w) => PLAIN[w] || m)            // any other database word: plain word
  .replace(/\s{2,}/g, " ").replace(/\s+([.,;])/g, "$1");

// lay the SQL out on several lines so it reads easily on the back of the card
function prettySql(sql) {
  // set quoted text aside first, lay out the keywords, then put the quoted text back
  const kept = [];
  const masked = sql.replace(/'[^']*'/g, m => `\u0000${kept.push(m) - 1}\u0000`);
  return layoutSql(masked).replace(/\u0000(\d+)\u0000/g, (_, i) => kept[i]);
}
function layoutSql(sql) {
  return sql.replace(/\s+/g, " ").trim()
    .replace(/\s+(FROM|WHERE|GROUP BY|HAVING|ORDER BY|LIMIT|UNION)\s+/gi, (m, k) => "\n" + k.toUpperCase() + " ")
    .replace(/\s+(AND|OR)\s+(?![^(]*\))/gi, (m, k) => "\n  " + k.toUpperCase() + " ")
    .replace(/^SELECT\s+/i, "SELECT ");
}
function setBusy(b) { document.querySelectorAll("#go, .starter, .chip, .topics button").forEach(x => x.disabled = b || !ready); }

// when every model is at its limit: say when it frees up, and offer three ready-made questions
function limitReached(res) {
  botSay(esc(res && res.wait_minutes ? t("limitIn", { m: res.wait_minutes }) : t("limit")));
  const ready = LIB.filter(q => !asked.has(q.id)).sort(() => Math.random() - 0.5).slice(0, 3);
  chipRow(ready, "");
}

// ---------- asking ----------
async function askWorker(payload) {
  const res = await fetch(WORKER_URL, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) });
  return res.json();
}
const needsGuess = () => $("guessOn").checked && $("guess").value.trim() === "";

async function submit(question, prepared) {
  if (!ready || !question) return;
  if (needsGuess()) { $("q").value = question; pendingPrepared = prepared || null; botSay(esc(t("needGuess"))); $("guess").focus(); return; }
  $("q").value = ""; pendingPrepared = null;
  meSay(question);
  const wait = typing(prepared ? t("running") : t("thinking"));
  setBusy(true);
  try {
    if (prepared) {   // prepared question: no AI needed
      asked.add(prepared.id);
      remember("user", question); remember("assistant", JSON.stringify({ status: "ok", sql: prepared.sql }));
      const r = await runSql(prepared.sql);
      wait.remove(); return answer(r, { sql: prepared.sql, prepared: true, question });
    }
    let ans = await askWorker({ question, history, lang });
    remember("user", question);
    remember("assistant", JSON.stringify({ status: ans.status, sql: ans.sql || "", clarification: ans.clarification || "" }));
    const say = (k) => { wait.remove(); botSay(esc(k === "ambiguous" ? plainNote(ans.clarification || t("error")) : t(k))); };
    if (ans.status === "limit") { wait.remove(); return limitReached(ans); }
    if (ans.status === "blocked") return say("blocked");
    if (ans.status === "ambiguous") {   // ask back, with the options as buttons the visitor can tap
      say("ambiguous");
      if (ans.options && ans.options.length) chipRow(ans.options.map(o => ({ en: o, fr: o, free: true })), "");
      return;
    }
    if (ans.status === "not_in_data") {   // explain why, then offer what the data can answer
      wait.remove(); botSay(esc(plainNote(ans.assumptions || t("notInData"))));
      if (ans.options && ans.options.length) chipRow(ans.options.map(o => ({ en: o, fr: o, free: true })), "");
      return;
    }
    if (ans.status === "not_a_data_question") return say("offTopic");
    if (ans.status !== "ok") return say("error");

    // value check, run, and the second chance
    wait.textContent = t("running");
    let r, problem = checkValues(ans.sql), retried = false;
    if (problem) problem = "Some values in that query do not exist in the data. " + problem;
    else if (/\b(nut|nuts|noix|fruits? à coque|cacahu)/i.test(question) && /not\s+list_contains\([^)]*\),\s*'nuts'\)/i.test(ans.sql) && !/'peanuts'/i.test(ans.sql))
      problem = "In everyday language 'nuts' includes peanuts. Exclude both 'nuts' and 'peanuts', and say so in assumptions.";
    else if (/\bnot\s+(no_(palm_oil|gluten|lactose|added_sugar)|pack_\w+)\b|\b(no_(palm_oil|gluten|lactose|added_sugar)|pack_\w+)\s*(=|is|<>|!=)\s*(not\s+)?(false|0)\b|\b(no_(palm_oil|gluten|lactose|added_sugar)|pack_\w+)\s*(<>|!=)\s*true\b|\bwhen\s+not\s+(no_|pack_)|\b100(\.0)?\s*-[^,]*\b(no_(palm_oil|gluten|lactose|added_sugar)|pack_\w+)/i.test(ans.sql))
      problem = "That query reads a missing claim or packaging value as its opposite. Follow rule 24: false means 'not stated on the pack', never the opposite.";
    else if (/allergens\s+is\s+null|allergens\s*=\s*''/i.test(ans.sql))
      problem = "A missing allergens value means unknown, not allergen-free. Follow rule 16: never treat missing allergens as allergen-free.";
    else {
      r = await runSql(ans.sql);
      if (r.error) problem = "That query failed in DuckDB with this error: " + r.error;
      else if (!r.rows.length)
        problem = "That query returned no products. If that is expected, return status not_in_data with a plain explanation in assumptions and 2 or 3 options; otherwise correct the query.";
      else if (r.rows.length && textCols(r.rows).some(k => r.rows[0][k] === null))
        problem = "The top row of that result is an unknown (NULL) value. Leave out NULL values with WHERE <column> IS NOT NULL.";
    }
    if (problem) {
      wait.textContent = t("retry"); retried = true;
      const fix = await askWorker({ question, lang, history, previous: { status: ans.status, sql: ans.sql, assumptions: ans.assumptions }, problem });
      if (fix.status === "not_in_data" || fix.status === "ambiguous") {
        wait.remove(); botSay(esc(plainNote(fix.assumptions || fix.clarification || t("noRows"))));
        if (fix.options && fix.options.length) chipRow(fix.options.map(o => ({ en: o, fr: o, free: true })), "");
        if (/allergen/i.test(question + ans.sql)) botSay(esc(t("allergyNote")));
        return;
      }
      if (fix.status === "limit") { wait.remove(); return limitReached(fix); }
      if (fix.status !== "ok") { wait.remove(); return botSay(esc(t("error"))); }
      ans = fix; r = await runSql(ans.sql);
      if (r.error) { wait.remove(); return botSay(esc(t("error"))); }
    }
    wait.remove();
    answer(r, { sql: ans.sql, model: ans.model, note: ans.assumptions, retried, question });
  } catch (e) { wait.remove(); botSay(esc(t("error"))); }
  finally { setBusy(false); }
}

// ---------- "Report a problem": one tap, details attached automatically, filed through the Worker ----------
async function sendReport(payload) {
  const res = await fetch(WORKER_URL + "/report", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) });
  return res.ok;
}
function openReport(face, payload) {
  if (face.querySelector(".rbox")) return;   // already open
  const box = document.createElement("div"); box.className = "rbox";
  box.innerHTML = `<div class="rq">${esc(t("reportAsk"))}</div><input type="text" maxlength="500" placeholder="${esc(t("reportPh"))}">
    <div class="rrow"><button class="rcancel">${esc(t("reportCancel"))}</button><button class="rsend">${esc(t("reportSend"))}</button></div>`;
  face.appendChild(box); box.querySelector("input").focus();
  box.querySelector(".rcancel").onclick = () => box.remove();
  box.querySelector(".rsend").onclick = async () => {
    box.querySelector(".rsend").disabled = true;
    const ok = await sendReport({ ...payload, comment: box.querySelector("input").value }).catch(() => false);
    box.innerHTML = `<div class="rq ${ok ? "ok" : ""}">${esc(ok ? t("reportThanks") : t("reportFail"))}</div>`;
    if (ok) face.querySelectorAll(".report").forEach(a => a.remove());
  };
}

// ---------- the answer: a card with the answer on the front and the query on the back ----------
function answer(r, info) {
  const data = (r.rows || []).map(row => {
    const o = { ...row };
    for (const k in o) {
      if (/year|annee|année|nova|grade/i.test(k) && typeof o[k] === "number") o[k] = String(o[k]);
      if (typeof o[k] === "boolean") o[k] = String(o[k]);
    }
    return o;
  });
  const cols = data.length ? Object.keys(data[0]) : [];
  const tc = textCols(data), nc = cols.filter(c => !tc.includes(c));
  const isUnknown = (row) => tc.some(k => row[k] === null);
  const sorted = [...data.filter(x => !isUnknown(x)), ...data.filter(isUnknown)];   // unknown groups go last, labelled
  let front = "";
  const single = data.length === 1 && cols.length === 1 && nc.length === 1;
  if (single) {
    front += `<div class="big">${fmtCol(cols[0], data[0][cols[0]])}</div><div class="cap">${esc(info.question)}</div>`;
  } else if (data.length === 1 && tc.length === 1 && nc.length === 1) {
    // one winner: show its name and its number, big
    const L = tc[0], V = nc[0], name = displayLabel(L, data[0][L]);
    front += `<div class="say">${esc(name ?? t("unknown"))}</div><div class="big">${fmtCol(V, data[0][V])}</div><div class="cap">${esc(pretty(V))}</div>`;
  } else if (tc.length === 1 && nc.length >= 1 && sorted.length <= 15) {
    // ranked list: a sentence first, then bars
    const L = tc[0], V = nc[nc.length - 1];
    const ordered = /year|annee|année|nova|grade/i.test(L);   // years, NOVA groups and grades keep their natural order
    const lowFirst = /nutriscore_score|score_nutri|points/i.test(V);
    if (!ordered) sorted.sort((a, b) => isUnknown(a) - isUnknown(b) || (lowFirst ? (a[V] ?? Infinity) - (b[V] ?? Infinity) : (b[V] ?? -Infinity) - (a[V] ?? -Infinity)));
    const top = sorted.filter(x => !isUnknown(x));
    const show = (v) => displayLabel(L, v);
    // is this a ranking (biggest first), or something in its own order, like years or grades?
    const lowerBetter = /nutriscore_score|score_nutri|points/i.test(V);
    const vals = top.map(x => x[V] ?? -Infinity);
    const ranked = !ordered;   // named lists are now sorted by their value
    const maxRow = top.reduce((m, x) => (m === null || (x[V] ?? -Infinity) > (m[V] ?? -Infinity) ? x : m), null);
    const minRow = top.reduce((m, x) => (m === null || (x[V] ?? Infinity) < (m[V] ?? Infinity) ? x : m), null);
    if (lowerBetter && minRow && sorted.length > 1) front += `<div class="say">${esc(t("lowest", { a: show(minRow[L]), v: fmt(minRow[V]) }))}</div>`;
    else if (ranked && top.length >= 2 && top[0][V] === top[1][V]) front += `<div class="say">${esc(t("tie", { a: show(top[0][L]), b: show(top[1][L]) }))}</div>`;
    else if (ranked && top.length >= 1 && sorted.length > 1) front += `<div class="say">${esc(t("first", { a: show(top[0][L]) }))}</div>`;
    else if (maxRow && sorted.length > 1) front += `<div class="say">${esc(t("highest", { a: show(maxRow[L]), v: fmt(maxRow[V]) }))}</div>`;
    const max = Math.max(...top.map(x => Math.abs(x[V] || 0)), 1e-9);
    const best = lowerBetter ? (minRow ? minRow[V] : null) : (maxRow ? maxRow[V] : null);
    // the highest value is dark; in a ranking the next one is mid-green; everything else is light
    const shade = (i, v) => v === best ? "var(--accent)" : ranked && i < 2 ? "var(--accent-2)" : "var(--accent-3)";
    front += `<div class="bars">` + sorted.map((x, i) => isUnknown(x)
      ? `<span class="unk">${t("unknown")}</span><span></span><span class="v unk">${fmt(x[V])}</span>`
      : `<span>${esc(show(x[L]))}</span><div class="b" style="width:${Math.max(2, 100 * Math.abs(x[V] || 0) / max)}%;background:${shade(i, x[V])}"></div><span class="v">${fmtCol(V, x[V])}</span>`).join("") + `</div>`;
    front += `<div class="cap">${esc(pretty(V))}</div>`;
  } else if (cols.includes("product_name")) {
    // list of products: name, brand underneath, and the key values as small tags
    const brandCol = ["brand_range", "brand_owner", "brand"].find(c => cols.includes(c));
    const skip = new Set(["product_name", "code", "brand_range", "brand_owner", "brand"]);
    const valueCols = cols.filter(c => !skip.has(c)).slice(0, 3);
    let row;   // the product currently being drawn, so a tag can read its other values
    const tag = (c, v) => {
      if (v === null) return "";
      if (c === "nutriscore_grade") return `<span class="tag ns">Nutri-Score ${esc(String(v).toUpperCase())}${row.nutriscore_score != null ? ` (${fmt(row.nutriscore_score)})` : ""}</span>`;
      if (c === "nutriscore_score" && cols.includes("nutriscore_grade")) return "";   // already shown with the grade
      if (c === "ecoscore_grade") return `<span class="tag">Eco-Score ${esc(String(v).toUpperCase())}</span>`;
      const unit = /_g$/.test(c) ? " g" : /kcal/.test(c) ? " kcal" : "";
      const name = c === "nutriscore_score" ? "Nutri-Score points" : PLAIN[c] || pretty(c).replace(/ g$/, "").replace(/ kcal$/, "");
      return `<span class="tag">${esc(name)} ${esc(fmt(v))}${unit}</span>`;
    };
    front += `<ul class="plist">` + sorted.slice(0, 10).map((r_, i) => (row = r_, `<li><span class="n">${i + 1}</span><div>
      <div class="name">${esc(row.product_name ?? t("unknown"))}</div>
      ${brandCol && row[brandCol] ? `<div class="pbrand">${esc(brandName(row[brandCol]))}</div>` : ""}
      <div class="tags">${valueCols.map(c => tag(c, row[c])).join("")}</div></div></li>`)).join("") + `</ul>`;
    if (sorted.length > 10) front += `<div class="cap">${t("rows", { k: 10, n: sorted.length })}</div>`;
  } else {
    const shown = sorted.slice(0, 20);
    const tcols = cols.slice(0, 5);
    front += `<table><tr>${tcols.map(c => `<th>${esc(pretty(c))}</th>`).join("")}</tr>` + shown.map(row => `<tr>${tcols.map(c =>
      `<td class="${typeof row[c] === "number" ? "num" : ""}">${row[c] === null ? t("unknown") : esc(fmtCol(c, typeof row[c] === "number" ? row[c] : displayLabel(c, row[c])))}</td>`).join("")}</tr>`).join("") + `</table>`;
    if (sorted.length > 20) front += `<div class="cap">${t("rows", { k: 20, n: sorted.length })}</div>`;
  }
  if (!data.length) front += `<div class="say">${esc(t("noRows"))}</div>`;
  if (info.note) front += `<div class="note">${esc(plainNote(info.note))}</div>`;
  if (/allergens/i.test(info.sql)) front += `<div class="note">${esc(t("allergyNote"))}</div>`;
  if ($("guessOn").checked && $("guess").value.trim() !== "") {
    const raw = $("guess").value.trim();
    if (single) {   // number answer: how far off was the guess?
      const g = Number(raw.replace(/\s/g, "").replace(",", ".").replace("%", "")), a = data[0][cols[0]];
      if (!isNaN(g)) { const p = a ? Math.abs(g - a) / Math.abs(a) * 100 : 0;
        front += `<div class="guessres">${t("guessRes", { g: fmt(g), a: fmt(a) })}<b>${p <= 5 ? t("close") : t("off", { p: fmt(Math.round(p)) })}</b></div>`; }
    } else {   // list answer: is the guessed name the winner, or near the top?
      const label = tc.find(c => c !== "code") || cols[0];
      const names = sorted.filter(x => !isUnknown(x)).map(x => String(x[label] ?? ""));
      const norm = (v) => v.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "");
      const g = norm(raw), hit = (n) => g.length >= 3 && (norm(n).includes(g) || g.includes(norm(n)));
      const k = names.findIndex(hit);
      const top = names[0] ?? "–";
      const verdict = k === 0 ? t("guessHit") : k > 0 && k < 3 ? t("guessNear", { k: k + 1, a: top })
                    : k >= 3 ? t("guessIn", { k: k + 1, a: top }) : t("guessMiss", { a: top });
      front += `<div class="guessres">${esc(t("yourGuess", { g: raw }))}<b>${esc(verdict)}</b></div>`;
    }
    $("guess").value = "";
  }

  // back of the card: the query and the checks it passed
  const checks = info.prepared ? [[t("cChip")]] : [[t("cSafe")], [t("cValues")], ...(info.retried ? [[t("cRetry"), "redo"]] : [])];
  checks.push([t("cRan", { n: fmt(TOTAL), ms: r.ms ?? "–" }) + (info.prepared ? "" : " · " + t("cWritten", { m: info.model }))]);
  const back = `<pre>${esc(prettySql(info.sql))}</pre><ul class="checks">${checks.map(([c, cls]) => `<li class="${cls || ""}">${esc(c)}</li>`).join("")}</ul>`;

  const summary = data.slice(0, 5).map(row => cols.map(c => row[c]).join(" | ")).join(" ; ") || t("noRows");
  const rep = `<button class="report" type="button">${t("report")}</button>`;
  const reportPayload = { question: info.question, answer: summary, sql: info.sql, model: info.prepared ? "prepared question" : info.model, lang };
  // small eye icon for "See query"
  const eye = `<svg class="eye" viewBox="0 0 24 24" width="14" height="14" aria-hidden="true"><path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z" fill="none" stroke="currentColor" stroke-width="2"/><circle cx="12" cy="12" r="3" fill="none" stroke="currentColor" stroke-width="2"/></svg>`;
  const sw = (on) => `<div class="sw"><button class="${on === "a" ? "on" : ""}" data-f="a">${t("fAnswer")}</button><button class="q ${on === "q" ? "on" : ""}" data-f="q">${eye}${t("fQuery")}</button></div>`;
  const card = document.createElement("div"); card.className = "flip";
  card.innerHTML = `<div class="in">
      <div class="face front"><div class="top">${rep}${sw("a")}</div>${front}</div>
      <div class="face back"><div class="top"><span class="sec" style="margin:0">${t("backTitle")}</span>${sw("q")}</div>${back}<div style="margin-top:10px">${rep}</div></div></div>`;
  card.querySelectorAll("[data-f]").forEach(b => b.onclick = () => card.classList.toggle("turned", b.dataset.f === "q"));
  card.querySelectorAll(".report").forEach(b => b.onclick = () => openReport(b.closest(".face"), reportPayload));
  add(card);
  chipRow(followUps(info.sql), t("alsoAsk"));
}

// ---------- side panel on phones: "About" opens it, tapping outside closes it ----------
$("menu").onclick = (e) => { e.stopPropagation(); $("side").classList.toggle("open"); };
document.addEventListener("click", (e) => { if (!$("side").contains(e.target) && e.target !== $("menu")) $("side").classList.remove("open"); });

// ---------- language switch and wiring ----------
let pendingPrepared = null;
function applyLang() {
  document.documentElement.lang = lang;
  document.querySelectorAll("[data-t]").forEach(el => el.textContent = t(el.dataset.t));
  $("q").placeholder = t("placeholder"); $("guess").placeholder = t("guessPh");
  document.querySelectorAll("[data-lang]").forEach(b => b.classList.toggle("on", b.dataset.lang === lang));
  renderTopics();
  // keep the conversation: only redraw the greeting if nothing has been asked yet
  if (!history.length) {
    greet();
    if (!ready) typing(t("loading")).id = "loadingMsg";
  }
  setBusy(false);
}
document.querySelectorAll("[data-lang]").forEach(b => b.onclick = () => { lang = b.dataset.lang; applyLang(); });
$("guessOn").onchange = () => { $("guess").hidden = !$("guessOn").checked; };
$("q").addEventListener("input", () => { pendingPrepared = null; });
$("go").onclick = () => {
  const q = $("q").value.trim();
  const prep = pendingPrepared && pendingPrepared[lang] === q ? pendingPrepared : null;
  submit(q, prep);
};
$("q").addEventListener("keydown", e => { if (e.key === "Enter") $("go").click(); });
$("guess").addEventListener("keydown", e => { if (e.key === "Enter") $("go").click(); });

applyLang();
startDb().then(() => { ready = true; $("loadingMsg")?.remove(); setBusy(false); })
         .catch(() => { $("loadingMsg") && ($("loadingMsg").textContent = t("error")); });
