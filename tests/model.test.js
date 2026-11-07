// node tests/model.test.js
const fs = require("fs"), path = require("path"), assert = require("assert")
const src = fs.readFileSync(path.join(__dirname, "..", "DriveModel.js"), "utf8").replace(".pragma library", "")
const m = {}; new Function("module", src)(m); const M = m.exports

const sample = JSON.stringify({ blockdevices: [
  { name: "sda", path: "/dev/sda", type: "disk", tran: "sata", rm: false, hotplug: false, size: 256e9,
    children: [{ name: "sda1", path: "/dev/sda1", type: "part", fstype: "vfat", mountpoint: "/boot", size: 2e9 }] },
  { name: "sdb", path: "/dev/sdb", type: "disk", tran: "usb", rm: true, hotplug: true, rota: false, size: 30.7e9, model: "SanDisk 3.2Gen1",
    children: [
      { name: "sdb1", path: "/dev/sdb1", type: "part", fstype: "exfat", label: "Synk<img src=x>", mountpoint: "/run/media/u/Synk", size: 30.6e9, fsused: 10e9, fssize: 30e9 },
      { name: "sdb2", path: "/dev/sdb2", type: "part", fstype: "vfat", label: "VTOYEFI", mountpoint: null, size: 32e6 }] },
  { name: "sdc", path: "/dev/sdc", type: "disk", tran: "usb", rm: false, hotplug: true, rota: true, size: 1e12, children: [] },
  { name: "sdd", path: "/dev/sdd", type: "disk", tran: "usb", rm: true, hotplug: true, size: 0 },
  { name: "zram0", path: "/dev/zram0", type: "disk", rm: false, hotplug: false, size: 16e9 }
]})

const drives = M.parseDrives(sample)
assert.deepStrictEqual(drives.map(d => d.name), ["sdb", "sdc"])
assert.strictEqual(drives[0].kind, "usb")
assert.strictEqual(drives[1].kind, "hdd")
assert.strictEqual(drives[0].parts.length, 2)
assert.strictEqual(M.primaryPart(drives[0]).name, "sdb1")
assert.strictEqual(M.formatBytes(30.7e9), "30.7 GB")
assert.strictEqual(M.parseDrives("not json").length, 0)
const d = M.diff([], drives)
assert.strictEqual(d.added.length, 2)
assert.strictEqual(d.newMounts.length, 1)
assert.strictEqual(M.diff(drives, []).removed.length, 2)
assert.ok(M.validDevice("/dev/sdb1"))
assert.ok(!M.validDevice("/dev/sdb1; rm -rf ~"))
assert.strictEqual(M.kindOf({ name: "nvme1n1", tran: "nvme" }), "nvme")
assert.strictEqual(M.usageLevel(0.35), "ok")
assert.strictEqual(M.usageLevel(0.75), "warn")
assert.strictEqual(M.usageLevel(0.95), "full")
const pal = M.parsePalette('red = "#c94f6d"\ngreen = "#81b29a"\ncolor3 = "#dbc074"\ncolor1 = "#000000"')
assert.deepStrictEqual([pal.red, pal.green, pal.yellow], ["#c94f6d", "#81b29a", "#dbc074"])
// strip: edges on the 1.25 pixel grid, ends flush, gaps equal, tiny parts kept visible
{
  const g = 1.25, W = 300.8
  const segs = M.stripLayout([30.6e9, 32e6], W, 1.6, 4.8, g)
  const onGrid = v => Math.abs(v * g - Math.round(v * g)) < 1e-9
  segs.forEach(s => { assert.ok(onGrid(s.x) && onGrid(s.x + s.w), JSON.stringify(s)) })
  assert.strictEqual(segs[0].x, 0)
  assert.ok(Math.abs(segs[1].x + segs[1].w - Math.round(W * g) / g) < 1e-9)
  assert.ok(segs[1].w >= 4.8 - 0.8)
  const three = M.stripLayout([1, 1, 1], 100, 1.6, 4.8, g)
  const gaps = [three[1].x - (three[0].x + three[0].w), three[2].x - (three[1].x + three[1].w)]
  gaps.forEach(gp => assert.ok(gp > 0 && onGrid(gp)))
  assert.deepStrictEqual(M.stripLayout([], 100, 2, 6, g), [])
}
// notification icons: valid SVG, all straight edges on whole pixels
{
  for (const kind of ["attached", "ejected", "removed", "warning"]) {
    const svg = M.notifyIconSvg(kind, 50, 3, "#cdcecf")
    assert.ok(svg.startsWith("<svg") && svg.endsWith("</svg>"))
    assert.ok(!/NaN|undefined/.test(svg), kind)
    // stroke 3 (odd): stroked paths at .5, filled rects at whole numbers
    const m = 3
    for (const r of svg.matchAll(/<rect x="([\d.]+)" y="([\d.]+)" width="([\d.]+)" height="([\d.]+)"/g)) {
      const [x, y, w, h] = r.slice(1).map(Number)
      const stroked = /rx="3" ?\/>$/.test(r.input.slice(r.index, r.input.indexOf(">", r.index) + 1)) && !/fill="#cdcecf"/.test(r.input.slice(r.index, r.input.indexOf(">", r.index)))
      const off = stroked ? m / 2 : 0
      for (const v of [x - off, y - off, x + w + off, y + h + off]) assert.ok(Number.isInteger(v), `${kind}: ${r[0]}`)
    }
  }
  assert.strictEqual(M.notifyFillSteps(50), 5)
}
console.log("ok")

// Level colours: real theme hues are kept, wrong or grey ones replaced by the right hue.
{
  const hue = h => M.hexToHsl(h).h
  const near = (h, c, w) => Math.min(Math.abs(h - c), 360 - Math.abs(h - c)) <= w
  const keep = M.levelPalette('mode = "dark"\ngreen = "#81b29a"\nyellow = "#dbc074"\nred = "#c94f6d"\n')
  assert.deepStrictEqual(keep, { ok: "#81b29a", warn: "#dbc074", full: "#c94f6d" })
  for (const text of ['green = "#4fe88f"\nyellow = "#50f7d4"\nred = "#50f872"', // all green
                      'green = "#b6b6b6"\nyellow = "#cecece"\nred = "#a4a4a4"', // grey
                      'mode = "light"\ngreen = "#3a3a3a"\nyellow = "#4a4a4a"\nred = "#2a2a2a"',
                      'color1 = "#F07178"\ncolor2 = "#C2B8FF"\ncolor3 = "#DDCCFF"', '']) {
    const p = M.levelPalette(text)
    assert.ok(near(hue(p.ok), 120, 50), "ok hue " + p.ok)
    assert.ok(near(hue(p.warn), 47, 20), "warn hue " + p.warn)
    assert.ok(near(hue(p.full), 355, 25), "full hue " + p.full)
  }
  assert.ok(M.hexToHsl(M.levelPalette('mode = "light"\ngreen = "#3a3a3a"').ok).l < 0.5, "darker on light themes")
  console.log("level palette ok")
}
