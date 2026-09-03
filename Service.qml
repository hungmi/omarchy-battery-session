import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Sampler. The shell creates exactly one of these (unlike bar widgets, which
// exist once per screen). Every 60 seconds it runs sample.sh, appends the
// returned line to the in-memory list and recomputes the summary for widgets.
Item {
  id: root

  property var shell: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string dataDir: (Quickshell.env("XDG_DATA_HOME") || home + "/.local/share") + "/battery-session"
  readonly property string samplerPath: String(Qt.resolvedUrl("sample.sh")).replace(/^file:\/\//, "")
  readonly property int intervalSec: 60
  // Only the last few months are loaded into memory; older files stay on disk
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

  // Startup: read history back from disk, then take the first sample right away.
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
        : code === 3 ? "errNoBattery"     // translated by the widget
        : code === 4 ? "errClock"
        : "sample.sh exit " + code
    }
  }
}
