.pragma library

// 中英文字串。lang 設定 auto 時看系統 locale：zh* 中文，其他英文。
var TABLE = {
  en: {
    current: "Battery life", last: "Last discharge",
    empty: "No discharge recorded yet", calibrating: "Calibrating… (needs two samples)",
    unplugged: "Unplugged at", now: "Now",
    elapsed: "Time since unplugged", slept: "Suspended / off", sleptWh: "Used while asleep", awake: "Time in use", power: "Discharging",
    nowW: "now", remaining: "Time left", curAvg: "session avg", histAvg: "all-time avg",
    tipAwake: "in use", tipRemainCur: "left (session avg)", tipRemainHist: "left (all-time avg)",
    onAc: "Plugged in", rightClick: "Right-click to change", histUse: "awake", histSlept: "suspended",
    err: "Sampler"
  },
  zh: {
    current: "電池續航力", last: "上次放電（目前接電中）",
    empty: "還沒有放電紀錄", calibrating: "還在收集中（校準 HZ 需要兩筆取樣）",
    unplugged: "停止充電於", now: "現在",
    elapsed: "拔電多久", slept: "睡/關", sleptWh: "睡/關耗掉", awake: "實際使用", power: "耗電速度",
    nowW: "現在", remaining: "還能用多久", curAvg: "本次平均", histAvg: "歷史平均",
    tipAwake: "實際使用", tipRemainCur: "還能用多久（本次平均）", tipRemainHist: "還能用多久（歷史平均）",
    onAc: "接電中", rightClick: "右鍵切換顯示", histUse: "實際", histSlept: "睡",
    err: "取樣器"
  }
}

function resolve(setting, localeName) {
  if (setting === "zh" || setting === "en") return setting
  return String(localeName || "").indexOf("zh") === 0 ? "zh" : "en"
}

function t(lang, key) {
  var tbl = TABLE[lang] || TABLE.en
  return tbl[key] !== undefined ? tbl[key] : (TABLE.en[key] || key)
}
