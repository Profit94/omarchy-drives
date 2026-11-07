.pragma library

// Pure helpers for the drives widget. Kept free of QML so tests can run in node.

var LSBLK_COLUMNS = "NAME,PATH,TYPE,TRAN,RM,HOTPLUG,ROTA,SIZE,FSTYPE,LABEL,MOUNTPOINT,FSUSED,FSSIZE,MODEL,VENDOR"
var SYSTEM_MOUNTS = ["/", "/boot", "/boot/efi", "/efi", "/home", "/usr", "/var", "[SWAP]"]

function clean(value, limit) {
  if (value === null || value === undefined) return ""
  return String(value).replace(/[\u0000-\u001f\u007f]/g, "").trim().slice(0, limit || 80)
}

function truthy(v) { return v === true || v === 1 || v === "1" || v === "true" }

function num(v) { var n = Number(v); return isFinite(n) && n > 0 ? n : 0 }

function flatten(node, out) {
  out.push(node)
  var kids = node.children || []
  for (var i = 0; i < kids.length; i++) flatten(kids[i], out)
  return out
}

function isSystemDisk(nodes) {
  for (var i = 0; i < nodes.length; i++)
    if (SYSTEM_MOUNTS.indexOf(nodes[i].mountpoint) >= 0) return true
  return false
}

function kindOf(disk) {
  var tran = clean(disk.tran).toLowerCase()
  var name = clean(disk.name)
  if (tran === "mmc" || /^mmcblk/.test(name)) return "sd"
  if (tran === "nvme" || /^nvme/.test(name)) return "nvme"
  // USB bridges often report sticks as rotational, so removable wins.
  if (tran === "usb" && truthy(disk.rm)) return "usb"
  if (truthy(disk.rota)) return "hdd"
  return tran === "usb" || tran === "sata" ? "ssd" : "disk"
}

// lsblk -J output -> list of removable drives with their filesystems.
function parseDrives(text) {
  var data
  try { data = JSON.parse(text) } catch (e) { return [] }
  var devices = (data && data.blockdevices) || []
  var drives = []
  for (var i = 0; i < devices.length && drives.length < 32; i++) {
    var d = devices[i]
    if (!d || d.type !== "disk") continue
    if (!(truthy(d.hotplug) || truthy(d.rm) || clean(d.tran) === "usb")) continue
    if (num(d.size) === 0) continue // empty card reader slot
    var nodes = flatten(d, [])
    if (isSystemDisk(nodes)) continue
    var parts = []
    for (var j = 0; j < nodes.length; j++) {
      var n = nodes[j]
      var leaf = !n.children || n.children.length === 0
      if (!leaf || !n.fstype) continue
      if (n.fstype === "swap") continue
      parts.push({
        name: clean(n.name, 32),
        path: clean(n.path, 64),
        label: clean(n.label, 48),
        fstype: clean(n.fstype, 16),
        size: num(n.size),
        mountpoint: clean(n.mountpoint, 256),
        used: num(n.fsused),
        total: num(n.fssize)
      })
    }
    var model = clean(d.model, 48) || clean(d.vendor, 32)
    var named = parts.filter(function(p) { return p.label !== "" && p.mountpoint !== "" })[0]
      || parts.filter(function(p) { return p.label !== "" })[0]
    drives.push({
      name: clean(d.name, 32),
      path: clean(d.path, 64),
      kind: kindOf(d),
      model: model,
      title: named ? named.label : (model || clean(d.name, 32)),
      size: num(d.size),
      tran: clean(d.tran, 12).toUpperCase(),
      parts: parts
    })
  }
  return drives
}

function mountedParts(drive) {
  return (drive && drive.parts || []).filter(function(p) { return p.mountpoint !== "" })
}

// Main filesystem: the mounted one with the most space, else the largest.
function primaryPart(drive) {
  var list = mountedParts(drive)
  if (list.length === 0) list = (drive && drive.parts) || []
  var best = null
  for (var i = 0; i < list.length; i++) if (!best || list[i].size > best.size) best = list[i]
  return best
}

// "30.8 GB". `formatNumber(value, decimals)` localises the number (Omarchy's
// Commons.I18n.formatNumber gives "30,8" in Danish); units stay as they are.
function formatBytes(bytes, formatNumber) {
  bytes = num(bytes)
  var units = ["B", "KB", "MB", "GB", "TB"]
  var i = 0
  while (bytes >= 1000 && i < units.length - 1) { bytes /= 1000; i++ }
  var decimals = i === 0 || bytes >= 100 ? 0 : 1
  var text = typeof formatNumber === "function" ? formatNumber(bytes, decimals) : bytes.toFixed(decimals)
  return text + " " + units[i]
}

// Error codes from bin/drive-action -> { key, arg } for a translated message,
// or null for a system message shown as it came.
function errorKey(reason) {
  var r = String(reason || "")
  if (r.indexOf("E:busy-by:") === 0) return { key: "err.busyBy", arg: clean(r.slice(10), 120) }
  var map = { "E:busy": "err.busy", "E:not-authorized": "err.notAuthorized",
              "E:mount-failed": "err.mountFailed", "E:not-device": "err.notDevice" }
  return map[r] ? { key: map[r], arg: "" } : null
}

function usageFraction(part) {
  if (!part || part.total <= 0) return 0
  return Math.max(0, Math.min(1, part.used / part.total))
}

function byName(drives) {
  var map = {}
  for (var i = 0; i < drives.length; i++) map[drives[i].name] = drives[i]
  return map
}

// Compare snapshots. Returns { added, removed, newMounts } where newMounts are
// parts that gained a mount point since the previous snapshot.
function diff(previous, next) {
  var before = byName(previous), after = byName(next)
  var added = [], removed = [], newMounts = []
  for (var k in after) {
    if (!before[k]) added.push(after[k])
    var oldMounts = {}
    if (before[k]) mountedParts(before[k]).forEach(function(p) { oldMounts[p.path] = true })
    mountedParts(after[k]).forEach(function(p) {
      if (!oldMounts[p.path]) newMounts.push({ drive: after[k], part: p })
    })
  }
  for (var r in before) if (!after[r]) removed.push(before[r])
  return { added: added, removed: removed, newMounts: newMounts }
}

// Storage level: "ok" under 70%, "warn" under 90%, "full" beyond.
function usageLevel(fraction) {
  return fraction >= 0.9 ? "full" : fraction >= 0.7 ? "warn" : "ok"
}

// Every hex colour in an Omarchy colors.toml, by key. color1..3 also fill
// red/green/yellow when the named keys are missing.
function parsePalette(text) {
  var out = {}
  var alias = { color1: "red", color2: "green", color3: "yellow" }
  String(text || "").split("\n").forEach(function(line) {
    var m = line.match(/^\s*([A-Za-z0-9_]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
    var mode = line.match(/^\s*mode\s*=\s*["']?(light|dark)/)
    if (mode) out.mode = mode[1]
    if (!m) return
    out[m[1]] = m[2]
    if (alias[m[1]] && !out[alias[m[1]]]) out[alias[m[1]]] = m[2]
  })
  return out
}

function hexToHsl(hex) {
  var n = parseInt(String(hex).slice(1), 16)
  var r = (n >> 16 & 255) / 255, g = (n >> 8 & 255) / 255, b = (n & 255) / 255
  var max = Math.max(r, g, b), min = Math.min(r, g, b), l = (max + min) / 2, d = max - min
  if (d === 0) return { h: 0, s: 0, l: l }
  var s = d / (1 - Math.abs(2 * l - 1))
  var h = max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4
  return { h: (h * 60 + 360) % 360, s: s, l: l }
}

function hslToHex(h, s, l) {
  var c = (1 - Math.abs(2 * l - 1)) * s, x = c * (1 - Math.abs((h / 60) % 2 - 1)), m = l - c / 2
  var rgb = h < 60 ? [c, x, 0] : h < 120 ? [x, c, 0] : h < 180 ? [0, c, x] : h < 240 ? [0, x, c] : h < 300 ? [x, 0, c] : [c, 0, x]
  return "#" + rgb.map(function(v) {
    var k = Math.round((v + m) * 255).toString(16)
    return k.length < 2 ? "0" + k : k
  }).join("")
}

// Green / yellow / red for the radar, taken from the theme when the theme's
// colour really has that hue. Many themes reuse those slots for their own
// accents (all green in hackerman, all blue in lumon, grey in vantablack,
// amber "green" in matte-black), which made the three levels look alike.
// A slot that fails the hue check tries its neighbours (bright_*, orange),
// then falls back to a plain hue at the theme's own lightness.
var LEVELS = {
  ok:   { keys: ["green", "bright_green"],                 lo: 68,  hi: 165, h: 140 },
  warn: { keys: ["yellow", "bright_yellow", "orange"],     lo: 28,  hi: 66,  h: 45 },
  full: { keys: ["red", "bright_red", "orange"],           lo: 335, hi: 20,  h: 355 }
}

function inHue(h, lo, hi) { return lo <= hi ? h >= lo && h <= hi : h >= lo || h <= hi }

function levelPalette(text) {
  var pal = parsePalette(text)
  var light = pal.mode ? pal.mode === "light" : (pal.background ? hexToHsl(pal.background).l > 0.5 : false)
  var out = {}, misses = [], lights = []
  Object.keys(LEVELS).forEach(function(level) {
    var spec = LEVELS[level]
    for (var i = 0; i < spec.keys.length; i++) {
      var hex = pal[spec.keys[i]]
      if (!hex) continue
      var c = hexToHsl(hex)
      if (c.s >= 0.18 && c.l >= 0.2 && c.l <= 0.85 && inHue(c.h, spec.lo, spec.hi)) {
        // orange may stand in for one level only
        if (spec.keys[i] === "orange" && Object.keys(out).some(function(k) { return out[k] === hex })) continue
        out[level] = hex; lights.push(c.l); return
      }
    }
    misses.push(level)
  })
  var l = lights.length ? lights.reduce(function(a, b) { return a + b }, 0) / lights.length : (light ? 0.4 : 0.64)
  l = light ? Math.min(0.48, Math.max(0.32, l)) : Math.min(0.72, Math.max(0.55, l))
  misses.forEach(function(level) { out[level] = hslToHex(LEVELS[level].h, light ? 0.65 : 0.6, l) })
  return out
}

// Segments of the partition strip, laid out by hand so every edge lands on a
// whole screen pixel. `grid` is the monitor scale (1.25 = 5 pixels per 4
// units). Each partition gets space in proportion to its size, never less
// than `minSeg`; gaps are `gap` wide. Returns [{ x, w }] in layout units.
function stripLayout(sizes, width, gap, minSeg, grid) {
  var n = sizes.length
  if (n === 0 || width <= 0) return []
  grid = grid > 0 ? grid : 1
  var snap = function(v) { return Math.round(v * grid) / grid }
  var total = sizes.reduce(function(a, b) { return a + Math.max(0, b) }, 0)
  var avail = Math.max(0, width - gap * (n - 1) - minSeg * n)
  var out = [], start = 0
  for (var i = 0; i < n; i++) {
    var share = total > 0 ? Math.max(0, sizes[i]) / total : 1 / n
    var w = minSeg + avail * share
    var x0 = snap(start), x1 = i === n - 1 ? snap(width) : snap(start + w)
    out.push({ x: x0, w: Math.max(0, x1 - x0) })
    start += w + gap
  }
  return out
}

// Notification icon: the bar's slab, drawn as an SVG on an n x n screen
// pixel grid (n = the toast's icon slot in screen pixels), so every straight
// edge lands on a whole pixel when the slot does. Strokes are centred on
// paths, so paths sit half a stroke inside whole-pixel lines.
//   kind "attached": light on, usage line filled `fillPx` design pixels
//   kind "ejected":  light off, empty line (safe to unplug)
//   kind "removed":  as ejected, the whole slab faded
//   kind "warning":  an exclamation mark in place of the light
function notifyIconSvg(kind, n, fillPx, color) {
  n = Math.max(16, Math.round(n))
  // The toast shows a sender's file as-is (only theme icons get tinted), so
  // the icon is drawn in the theme's notification text colour itself.
  var ink = /^#[0-9a-fA-F]{6}$/.test(String(color || "")) ? String(color) : "#ffffff"
  var m = Math.max(1, Math.floor(n / 15))          // design pixel
  var h = m / 2
  var faceW = n - 2 * m, topH = 4 * m, faceH = 7 * m
  var top = Math.floor((n - topH - faceH) / 2)
  var faceX = m, faceY = top + topH
  var lineX = faceX + 2 * m, lineY = faceY + 3 * m
  var lineW = Math.max(m, faceW - 9 * m)
  var ledX = faceX + faceW - 2 * m - 3 * m, ledY = faceY + 2 * m
  var fill = Math.max(0, Math.min(lineW, Math.round(fillPx || 0) * m))
  var out = []
  out.push('<svg xmlns="http://www.w3.org/2000/svg" width="' + n + '" height="' + n + '" viewBox="0 0 ' + n + ' ' + n + '">')
  out.push('<g fill="none" stroke="' + ink + '" stroke-width="' + m + '" stroke-linejoin="round"' + (kind === "removed" ? ' opacity="0.5"' : '') + '>')
  // Top face, tinted
  out.push('<path fill="' + ink + '" fill-opacity="0.14" d="M' + (3 * m + h) + ' ' + (top + h) + 'H' + (n - 3 * m - h)
    + 'L' + (faceX + faceW - h) + ' ' + (faceY + h) + 'H' + (faceX + h) + 'Z"/>')
  // Front face
  out.push('<rect x="' + (faceX + h) + '" y="' + (faceY + h) + '" width="' + (faceW - m) + '" height="' + (faceH - m) + '" rx="' + m + '"/>')
  out.push('</g>')
  var g = kind === "removed" ? ' opacity="0.5"' : ''
  // Usage line: track, then the used part
  out.push('<rect x="' + lineX + '" y="' + lineY + '" width="' + lineW + '" height="' + m + '" fill="' + ink + '" fill-opacity="0.3"' + g + '/>')
  if (kind === "attached" && fill > 0)
    out.push('<rect x="' + lineX + '" y="' + lineY + '" width="' + fill + '" height="' + m + '" fill="' + ink + '"/>')
  if (kind === "warning") {
    // ! in the light's column, inside the face's 5 inner rows:
    // bar on rows 1-2, gap, dot on row 4, gap above the bottom border.
    out.push('<rect x="' + (ledX + m) + '" y="' + (faceY + m) + '" width="' + m + '" height="' + (2 * m) + '" fill="' + ink + '"/>')
    out.push('<rect x="' + (ledX + m) + '" y="' + (faceY + 4 * m) + '" width="' + m + '" height="' + m + '" fill="' + ink + '"/>')
  } else {
    out.push('<rect x="' + ledX + '" y="' + ledY + '" width="' + (3 * m) + '" height="' + (3 * m) + '" rx="' + (1.5 * m) + '" fill="' + ink + '"'
      + (kind === "attached" ? '' : ' fill-opacity="0.25"') + g + '/>')
  }
  out.push('</svg>')
  return out.join("")
}

// Design pixels in a notification icon's usage line, for a used fraction.
function notifyFillSteps(n) {
  n = Math.max(16, Math.round(n)); var m = Math.max(1, Math.floor(n / 15))
  return Math.max(1, Math.floor((n - 2 * m - 9 * m) / m))
}

function validDevice(path) { return /^\/dev\/[A-Za-z0-9._-]+$/.test(String(path || "")) }

if (typeof module !== "undefined") module.exports = {
  parseDrives: parseDrives, primaryPart: primaryPart, mountedParts: mountedParts,
  formatBytes: formatBytes, usageFraction: usageFraction, diff: diff, validDevice: validDevice, kindOf: kindOf, errorKey: errorKey, usageLevel: usageLevel, parsePalette: parsePalette, levelPalette: levelPalette, hexToHsl: hexToHsl, stripLayout: stripLayout, notifyIconSvg: notifyIconSvg, notifyFillSteps: notifyFillSteps
}
