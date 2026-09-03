import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// 取樣器。shell 只建一份（不像 bar widget 每個螢幕一份），每 60 秒跑一次
// sample.sh，把回來的那一行接到記憶體裡的列表，重算摘要給 widget 讀。
Item {
  id: root

  property var shell: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string dataDir: (Quickshell.env("XDG_DATA_HOME") || home + "/.local/share") + "/battery-session"
  readonly property string samplerPath: String(Qt.resolvedUrl("sample.sh")).replace(/^file:\/\//, "")
  readonly property int intervalSec: 60
  // 只載入最近幾個月進記憶體；更早的留在磁碟給人看
  readonly property int loadMonths: 3

  property var rows: []
  property var summary: Model.summarize([], 0)
  property bool loaded: false
  property string lastError: ""

  function recompute() {
    root.summary = Model.summarize(root.rows, Math.floor(Date.now() / 1000))
  }

  function sample() {
    if (sampleProc.running) return
    sampleProc.running = true
  }

  // 啟動：把磁碟上的歷史讀回來，然後立刻取第一筆。
  Process {
    id: loadProc
    running: true
    command: ["bash", "-c", 'ls -1 "$0"/*.tsv 2>/dev/null | sort | tail -n "$1" | xargs -r cat', root.dataDir, String(root.loadMonths)]
    stdout: StdioCollector {
      onStreamFinished: {
        root.rows = Model.parseRows(text)
        root.loaded = true
        root.recompute()
        root.sample()
      }
    }
  }

  Timer {
    interval: root.intervalSec * 1000
    running: root.loaded
    repeat: true
    onTriggered: root.sample()
  }

  Process {
    id: sampleProc
    running: false
    command: ["bash", root.samplerPath]
    stdout: StdioCollector {
      onStreamFinished: {
        var r = Model.parseRow(String(text).trim())
        if (!r) return
        root.rows = Model.appendRow(root.rows, r)
        root.recompute()
      }
    }
    onExited: function(code) {
      root.lastError = code === 0 ? ""
        : code === 3 ? "沒有電池"
        : code === 4 ? "系統時鐘還沒同步"
        : "sample.sh exit " + code
    }
  }
}
