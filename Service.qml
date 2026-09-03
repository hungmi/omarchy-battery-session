import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Sampler. The shell creates exactly one of these (unlike bar widgets, which
// exist once per screen). Every 60 seconds it runs sample.sh, appends the
// returned line to the in-memory list and recomputes the summary for widgets.
//
// Process hygiene: the only child process is /usr/bin/bash by absolute path,
// started with a cleared environment (PATH=/usr/bin, LC_ALL=C), no profile or
// rc files, stderr closed, a hard deadline (TERM then KILL), and explicit
// teardown on destruction. sample.sh itself is bash builtins plus
// /usr/bin/mkdir and /usr/bin/rm by absolute path. History is read with
// FileView, not a shell pipeline, and is capped by bytes and rows.
Item {
  id: root

  property var shell: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string dataDir: home + "/.local/share/battery-session"
  readonly property string samplerPath: String(Qt.resolvedUrl("sample.sh")).replace(/^file:\/\//, "")
  readonly property int intervalSec: 60
  readonly property int deadlineSec: 20          // sample.sh normally finishes in well under a second
  // Only the last few months are loaded into memory; older files stay on disk.
  readonly property int loadMonths: 3
  readonly property int maxFileBytes: 16 * 1024 * 1024   // a month at one row per minute is ~2.5 MB
  readonly property int maxRows: 150000                  // ~3.4 months at one row per minute
  readonly property int maxLineChars: 256

  property var rows: []
  property var summary: Model.summarize([], 0)
  property bool loaded: false
  property string lastError: ""

  function recompute() {
    root.summary = Model.summarize(root.rows, Math.floor(Date.now() / 1000))
  }

  // ---- history: the current month and the loadMonths-1 before it ----
  readonly property var monthFiles: {
    var out = [], d = new Date()
    for (var i = root.loadMonths - 1; i >= 0; i--) {
      var m = new Date(d.getFullYear(), d.getMonth() - i, 1)
      var mm = m.getMonth() + 1
      out.push(root.dataDir + "/" + m.getFullYear() + "-" + (mm < 10 ? "0" : "") + mm + ".tsv")
    }
    return out
  }
  property int loadIdx: 0
  property string loadedText: ""

  FileView {
    id: history
    printErrors: false
    watchChanges: false
    path: root.loadIdx < root.monthFiles.length ? root.monthFiles[root.loadIdx] : ""
    // Changing `path` inside these handlers makes Quickshell drop the next
    // load ("operation finished from dropped operation"), so advance later.
    onLoaded: {
      // Files over the cap are skipped rather than parsed: fail closed.
      if (data().byteLength <= root.maxFileBytes) root.loadedText += text() + "\n"
      Qt.callLater(root.nextFile)
    }
    onLoadFailed: Qt.callLater(root.nextFile)     // month without data, or unreadable: skip it
  }
  function nextFile() { root.loadIdx++ }

  onLoadIdxChanged: if (loadIdx >= monthFiles.length && !loaded) finishLoad()

  function finishLoad() {
    var parsed = Model.parseRows(root.loadedText)
    root.loadedText = ""
    if (parsed.length > root.maxRows) parsed = parsed.slice(parsed.length - root.maxRows)
    root.rows = parsed
    root.loaded = true
    root.recompute()
    root.sample()
  }

  // ---- sampling ----
  function sample() {
    if (sampleProc.running) return
    sampleProc.running = true
    deadline.restart()
  }

  Timer {
    id: tick
    interval: root.intervalSec * 1000
    running: root.loaded
    repeat: true
    onTriggered: root.sample()
  }

  // Hard deadline: TERM at deadlineSec, KILL five seconds later.
  Timer {
    id: deadline
    interval: root.deadlineSec * 1000
    onTriggered: if (sampleProc.running) { sampleProc.signal(15); killer.restart() }
  }
  Timer {
    id: killer
    interval: 5000
    onTriggered: if (sampleProc.running) sampleProc.signal(9)
  }

  Process {
    id: sampleProc
    running: false
    command: ["/usr/bin/bash", "--noprofile", "--norc", root.samplerPath]
    clearEnvironment: true
    // TZ is passed through (null = system value) so the month file the sampler
    // writes matches the month file names this service computes with Date.
    environment: ({ PATH: "/usr/bin", LC_ALL: "C", TZ: null })
    stdinEnabled: false
    stderr: null
    stdout: StdioCollector {
      onStreamFinished: {
        var line = String(text).trim()
        if (line.length > root.maxLineChars) return      // not our sampler's output: ignore
        var r = Model.parseRow(line)
        if (!r) return
        root.rows = Model.appendRow(root.rows, r)
        if (root.rows.length > root.maxRows) root.rows = root.rows.slice(root.rows.length - root.maxRows)
        root.recompute()
      }
    }
    onExited: function(code, status) {
      deadline.stop(); killer.stop()
      root.lastError = status !== 0 ? "errKilled"
        : code === 0 ? ""
        : code === 3 ? "errNoBattery"     // translated by the widget
        : code === 4 ? "errClock"
        : code === 5 ? "errDataDir"
        : "sample.sh exit " + code
    }
  }

  Component.onDestruction: {
    tick.stop(); deadline.stop(); killer.stop()
    if (sampleProc.running) sampleProc.signal(15)
  }
}
