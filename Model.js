.pragma library

// 讀取端演算法。從 sample.sh 寫的 TSV 算出每段放電的拔電時間、醒著時間、耗電。
// 醒著時間 = 相鄰兩筆 jiffies 差 / HZ 的累加。jiffies 只在醒著時前進，suspend
// 時凍結，開機歸零（用 boot 偵測），所以不需要每筆都取樣到——下一筆自動補回差額。

var SANE_WALL = 1500000000      // 2017。開機時還沒 NTP 同步的列是垃圾
var WH_JITTER = 1.0             // 放電中電量上升超過這個值 = 中途充過電。電量計本身會飄 ±0.6
var SLEEP_GAP = 120             // 相鄰兩筆 wall 差比 jiffies 差多超過這麼多秒 = 中間睡過
var MIN_HIST_AWAKE = 600        // 歷史平均只算醒著 ≥10 分鐘的 session
var HZ_CANDIDATES = [100, 250, 300, 1000]

function parseRow(line) {
  var p = String(line).split("\t")
  if (p.length < 8 || !/^\d+$/.test(p[0])) return null
  var wall = parseInt(p[0], 10)
  if (wall < SANE_WALL) return null
  return {
    wall: wall, jiffies: parseFloat(p[1]), boot: p[2],
    pct: p[3], state: p[4], ac: p[5],
    wh: p[6] === "" ? null : parseFloat(p[6]),
    pw: p[7] === "" || p[7] === undefined ? null : parseFloat(p[7])
  }
}

// 檔案本來就照時間 append，不排序——wall 跳動時排序反而會打亂順序。
function parseRows(text) {
  var out = [], seen = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var r = parseRow(lines[i])
    if (!r || seen[r.wall]) continue
    seen[r.wall] = true
    out.push(r)
  }
  return out
}

function appendRow(rows, r) {
  if (!r) return rows
  if (rows.length && rows[rows.length - 1].wall === r.wall) return rows
  return rows.concat([r])
}

// HZ = jiffies差 / 秒差，取相鄰一分鐘內的配對的中位數，湊到常見值。
// 有 suspend 的配對 wall 差會很大，被 dw <= 130 排掉；漏網的靠中位數吃掉。
function detectHz(rows) {
  var rates = []
  for (var i = 1; i < rows.length; i++) {
    var a = rows[i - 1], b = rows[i]
    if (a.boot !== b.boot) continue
    var dw = b.wall - a.wall
    if (dw < 30 || dw > 130) continue
    rates.push((b.jiffies - a.jiffies) / dw)
  }
  if (!rates.length) return 0
  rates.sort(function(x, y) { return x - y })
  var med = rates[Math.floor(rates.length / 2)]
  var best = HZ_CANDIDATES[0]
  for (var k = 1; k < HZ_CANDIDATES.length; k++)
    if (Math.abs(HZ_CANDIDATES[k] - med) < Math.abs(best - med)) best = HZ_CANDIDATES[k]
  return best
}

function onBattery(r) {
  return (r.ac === "0" || r.ac === "1") ? r.ac === "0" : r.state === "Discharging"
}

// 切成一段段放電：ac 翻回 1 就結束；取樣有斷（間隔 > SLEEP_GAP）且電量升了也切——
// 那是空白期間插過電又拔掉。連續取樣時一律信 ac：高負載會把電量計讀數暫時壓低，
// 負載掉了讀數彈回 +1 Wh 以上，不能當成充過電（2026-09-03 實際誤切過一次）。
// ac 翻回 1 的那筆若電量比最後放電筆低，就併進來當終點：睡覺/沒電關機期間沒取樣，
// 醒來第一筆已經插電，不併的話整晚掉的電和時間都會消失。
function sessions(rows) {
  var out = [], cur = []
  for (var i = 0; i < rows.length; i++) {
    var r = rows[i]
    if (!onBattery(r)) {
      if (cur.length) {
        var last = cur[cur.length - 1]
        if (last.wh !== null && r.wh !== null && r.wh < last.wh) cur.push(r)
        out.push(cur)
      }
      cur = []
      continue
    }
    if (cur.length && cur[cur.length - 1].wh !== null && r.wh !== null
        && r.wall - cur[cur.length - 1].wall > SLEEP_GAP
        && r.wh > cur[cur.length - 1].wh + WH_JITTER) {
      out.push(cur)
      cur = []
    }
    cur.push(r)
  }
  if (cur.length) out.push(cur)
  return out
}

function awakeSecs(seg, hz) {
  var total = 0
  for (var i = 1; i < seg.length; i++) {
    var a = seg[i - 1], b = seg[i]
    if (a.boot !== b.boot) continue            // 跨重開機：時鐘歸零，且那段機器是關的
    var d = (b.jiffies - a.jiffies) / hz
    var dw = b.wall - a.wall
    if (d > 0) total += dw > 0 ? Math.min(d, dw) : d   // 正常 d ≤ dw，用 dw 夾住；wall 倒退只信 jiffies
  }
  return total
}

// 醒著時耗的電：只累加「中間沒睡」的相鄰配對的 Wh 差。睡覺約 1 W 但分母只算醒著，
// 混在一起平均瓦數會高估 20%，續航就少估。睡覺耗的另外算成 sleptWh。
function awakeWh(seg, hz) {
  var total = 0
  for (var i = 1; i < seg.length; i++) {
    var a = seg[i - 1], b = seg[i]
    if (a.wh === null || b.wh === null || a.boot !== b.boot) continue
    var d = (b.jiffies - a.jiffies) / hz, dw = b.wall - a.wall
    if (dw - d > SLEEP_GAP) continue
    if (a.wh > b.wh) total += a.wh - b.wh
  }
  return total
}

function summarizeSeg(seg, hz, live, now) {
  var start = seg[0], end = seg[seg.length - 1]
  var wall = (live ? now : end.wall) - start.wall
  var awake = awakeSecs(seg, hz)
  var used = (start.wh !== null && end.wh !== null) ? start.wh - end.wh : null
  if (used !== null && used <= 0) used = null
  var aw = used !== null ? Math.min(used, awakeWh(seg, hz)) : null
  return {
    live: live,
    startWall: start.wall, endWall: end.wall,
    startPct: start.pct, endPct: end.pct,
    wallSecs: wall, awakeSecs: awake, sleptSecs: Math.max(0, wall - awake),
    usedWh: used, awakeWh: aw,
    sleptWh: used !== null ? used - aw : null,
    avgW: (aw !== null && aw > 0 && awake > 0) ? aw * 3600 / awake : null
  }
}

// 主入口。state: "empty" 沒資料 / "calibrating" 還推不出 HZ / "ok"
function summarize(rows, now) {
  var hz = detectHz(rows)
  var segs = sessions(rows)
  var last = rows.length ? rows[rows.length - 1] : null
  var live = last ? onBattery(last) : false
  var out = { state: rows.length ? (hz ? "ok" : "calibrating") : "empty",
              hz: hz, live: live, current: null, history: [], lastWall: last ? last.wall : 0 }
  if (!hz || !segs.length) return out
  var all = []
  for (var i = 0; i < segs.length; i++)
    all.push(summarizeSeg(segs[i], hz, live && i === segs.length - 1, now))
  out.current = all[all.length - 1]
  // 歷史列表：不含本次，最多 8 條。短的也列（使用者要看到每次拔電）
  out.history = all.slice(0, -1)
  out.history = out.history.slice(Math.max(0, out.history.length - 8)).reverse()

  // 歷史平均功率：所有放電段（含本次）醒著耗電 / 總醒著秒數，長的 session 權重自然大
  var wh = 0, secs = 0
  for (var k = 0; k < all.length; k++) {
    if (all[k].awakeWh === null || all[k].awakeSecs < MIN_HIST_AWAKE) continue
    wh += all[k].awakeWh; secs += all[k].awakeSecs
  }
  out.histAvgW = secs > 0 ? wh * 3600 / secs : null

  // 還能用多久 = 剩餘 Wh / 功率。只在放電中、且知道剩多少電時有意義
  var lastWh = rows[rows.length - 1].wh
  if (live && lastWh !== null) {
    var c = out.current
    c.remainWh = lastWh
    c.nowW = rows[rows.length - 1].pw !== null ? Math.abs(rows[rows.length - 1].pw) : null   // 最後一筆的瞬時功率
    c.remainCurSecs = c.avgW ? lastWh * 3600 / c.avgW : null
    c.remainHistSecs = out.histAvgW ? lastWh * 3600 / out.histAvgW : null
  }
  return out
}

function hm(s) {
  s = Math.max(0, Math.floor(s))
  var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60)
  return h + "h " + (m < 10 ? "0" : "") + m + "m"
}

function pad2(n) { return (n < 10 ? "0" : "") + n }

function clock(wall) {
  var d = new Date(wall * 1000)
  return pad2(d.getMonth() + 1) + "-" + pad2(d.getDate()) + " " + pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}
