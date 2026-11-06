// node tests/i18n.test.js — every catalog matches en.json: same keys, same
// %N placeholders, no empty strings, and exactly the plural categories
// Omarchy's Plural.js asks of that language.
const fs = require("fs"), path = require("path"), assert = require("assert")
const dir = path.join(__dirname, "..", "i18n")
const omarchy = process.env.OMARCHY_PATH || "/usr/share/omarchy"
const src = fs.readFileSync(path.join(omarchy, "shell/Commons/Plural.js"), "utf8")
  .replace(/^\.pragma.*$/m, "").replace(/^\.import.*$/mg, "")
const P = {}; new Function("module", src + ";module.exports={categories:categories};")(P)
const locales = Object.keys(JSON.parse(fs.readFileSync(path.join(omarchy, "default/i18n/locales.json"), "utf8")))

const en = JSON.parse(fs.readFileSync(path.join(dir, "en.json"), "utf8"))
const holes = s => [...new Set(String(s).match(/%\d/g) || [])].sort().join(",")
const forms = v => typeof v === "object" ? Object.values(v) : [v]

let checked = 0
for (const lang of locales) {
  const file = path.join(dir, lang + ".json")
  assert.ok(fs.existsSync(file), "missing catalog: " + lang)
  const cat = JSON.parse(fs.readFileSync(file, "utf8"))
  assert.deepStrictEqual(Object.keys(cat).sort(), Object.keys(en).sort(), lang + ": keys differ")
  for (const key of Object.keys(en)) {
    const want = holes(forms(en[key])[0])
    for (const s of forms(cat[key])) {
      assert.ok(typeof s === "string" && s.trim().length > 0, `${lang}.${key}: empty`)
      assert.strictEqual(holes(s), want, `${lang}.${key}: placeholders ${holes(s)} vs ${want}`)
      assert.ok(!/[<>]/.test(s), `${lang}.${key}: markup-like text`)
    }
    if (typeof en[key] === "object")
      assert.deepStrictEqual(Object.keys(cat[key]).sort(), P.exports.categories(lang).slice().sort(), `${lang}.${key}: plural categories`)
  }
  checked++
}
console.log("ok", checked, "catalogs")
