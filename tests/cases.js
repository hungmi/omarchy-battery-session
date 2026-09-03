// Model.js 的 sessions() 切段測試。開發者用：node tests/cases.js
// plugin 本身不需要 node；Model.js 是純 JS 才能這樣跑。
const fs = require("fs"), vm = require("vm"), path = require("path")

const ctx = {}
vm.createContext(ctx)
vm.runInContext(fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8").replace(/^\.pragma.*$/m, ""), ctx)

// 每筆 [第幾分鐘, ac, wh, 之前在睡]。jiffies 只在醒著時前進。
const T0 = 1788400000, HZ = 1000
function rows(spec) {
  let jif = 1e9, prev = 0, out = []
  for (const [min, ac, wh, asleep] of spec) {
    jif += asleep ? 0 : (min - prev) * 60 * HZ
    out.push({ wall: T0 + min * 60, jiffies: jif, boot: "b", pct: "50",
               state: ac === "1" ? "Charging" : "Discharging", ac, wh, pw: -5 })
    prev = min
  }
  return out
}

// 預期值 = 每段「起點Wh→終點Wh」
const cases = [
  ["連續取樣，讀數飄動升 1.3（高負載後回彈，不是充電）",
   rows([[0,"0",26.0],[1,"0",25.7],[2,"0",27.0],[3,"0",26.9]]), ["26→26.9"]],
  ["shell 沒開兩小時，中間插過電又拔掉",
   rows([[0,"0",20.5],[1,"0",20.0],[121,"0",35.0],[122,"0",34.9]]), ["20.5→20", "35→34.9"]],
  ["正常插電，ac 翻 1 結束",
   rows([[0,"0",20.5],[1,"0",20.0],[2,"1",20.1],[3,"1",20.5]]), ["20.5→20"]],
  ["睡一小時沒插電",
   rows([[0,"0",20.5],[1,"0",20.0],[61,"0",19.2,1],[62,"0",19.1]]), ["20.5→19.1"]],
  ["睡一小時插電，醒來還插著；ac=1 那筆電量較低才併入，這裡較高所以不併",
   rows([[0,"0",20.5],[1,"0",20.0],[61,"1",35.0,1],[62,"1",35.5]]), ["20.5→20"]],
  ["睡一小時插電，醒來前拔掉",
   rows([[0,"0",20.5],[1,"0",20.0],[61,"0",35.0,1],[62,"0",34.9]]), ["20.5→20", "35→34.9"]],
  ["睡覺中只充 0.5 Wh，低於門檻，已知會漏",
   rows([[0,"0",20.5],[1,"0",20.0],[61,"0",20.5,1],[62,"0",20.4]]), ["20.5→20.4"]],
  ["睡覺/沒電關機時掉電，醒來已插電：ac=1 那筆併入當終點",
   rows([[0,"0",20.5],[1,"0",20.0],[481,"1",5.0,1],[482,"1",5.5]]), ["20.5→5"]],
]

let fail = 0
for (const [name, rs, want] of cases) {
  const got = ctx.sessions(rs).map(s => `${s[0].wh}→${s[s.length - 1].wh}`)
  const ok = JSON.stringify(got) === JSON.stringify(want)
  if (!ok) fail++
  console.log(`${ok ? "ok  " : "FAIL"} ${name}`)
  if (!ok) console.log(`       想要 ${want.join(" | ")}\n       得到 ${got.join(" | ")}`)
}
console.log(fail ? `\n${fail} 個失敗` : `\n${cases.length} 個全過`)
process.exit(fail ? 1 : 0)
