import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Sampler. The shell creates exactly one of these (unlike bar widgets, which
// exist once per screen). Every 60 seconds it runs sample.sh, appends the
// returned line to the in-memory list and recomputes the summary for widgets.
//
// Process hygiene: the only child process is /usr/bin/bash by absolute path,
// started with a cleared environment (PATH=/usr/bin, LC_ALL=C, TZ), no
// profile or rc files, stdin and stderr closed, a hard deadline (TERM then
// KILL), and explicit teardown on destruction. sample.sh is bash builtins plus
// /usr/bin/dd, /usr/bin/mkdir and /usr/bin/rm by absolute path; every file it
// opens uses O_NOFOLLOW and O_NONBLOCK, and every read is capped by bytes on
// the producer side (see sample.sh). Nothing here touches the data files
// directly.
Item {
  id: root

  property var shell: null

  readonly property string samplerPath: String(Qt.resolvedUrl("sample.sh")).replace(/^file:\/\//, "")
  readonly property int intervalSec: 60
  readonly property int sampleDeadlineSec: 20     // sample.sh normally finishes in well under a second
  readonly property int loadDeadlineSec: 30
  // sample.sh load emits at most 3 files x 4 MiB; anything larger is not our sampler.
  readonly property int maxLoadChars: 3 * 4194304 + 64
  readonly property int maxRows: 150000           // ~3.4 months at one row per minute
  readonly property int maxLineChars: 256

  property var rows: []
  property var summary: Model.summarize([], 0)
  property bool loaded: false
  property string lastError: ""

  function recompute() {
    root.summary = Model.summarize(root.rows, Math.floor(Date.now() / 1000))
  }
  function capRows(list) {
    return list.length > root.maxRows ? list.slice(list.length - root.maxRows) : list
  }

  // ---- shared process settings ----
  readonly property var bashCommand: ["/usr/bin/bash", "--noprofile", "--norc", root.samplerPath]
  // TZ is passed through (null = system value) so the month file names the
  // sampler uses match the calendar the user sees.
  readonly property var cleanEnvironment: ({ PATH: "/usr/bin", LC_ALL: "C", TZ: null })

  // Hard deadline for whichever process is running: TERM, then KILL 5 s later.
  property var watched: null
  function watch(proc, secs) { root.watched = proc; deadline.interval = secs * 1000; deadline.restart() }
  Timer {
    id: deadline
    onTriggered: if (root.watched && root.watched.running) { root.watched.signal(15); killer.restart() }
  }
  Timer {
    id: killer
    interval: 5000
    onTriggered: if (root.watched && root.watched.running) root.watched.signal(9)
  }
  function unwatch() { deadline.stop(); killer.stop(); root.watched = null }

  // ---- startup: bounded history dump, then the first sample ----
  Process {
    id: loadProc
    running: true
    command: root.bashCommand.concat(["load"])
    clearEnvironment: true
    environment: root.cleanEnvironment
    stdinEnabled: false
    stderr: null
    stdout: StdioCollector {
      onStreamFinished: {
        var t = String(text)
        root.rows = t.length <= root.maxLoadChars ? root.capRows(Model.parseRows(t)) : []
      }
    }
    onStarted: root.watch(loadProc, root.loadDeadlineSec)
    onExited: function(code, status) {
      root.unwatch()
      root.loaded = true
      root.recompute()
      root.sample()
    }
  }

  // ---- sampling ----
  function sample() {
    if (sampleProc.running || loadProc.running) return
    sampleProc.running = true
  }

  Timer {
    id: tick
    interval: root.intervalSec * 1000
    running: root.loaded
    repeat: true
    onTriggered: root.sample()
  }

  Process {
    id: sampleProc
    running: false
    command: root.bashCommand
    clearEnvironment: true
    environment: root.cleanEnvironment
    stdinEnabled: false
    stderr: null
    stdout: StdioCollector {
      onStreamFinished: {
        var line = String(text).trim()
        if (line.length > root.maxLineChars) return      // not our sampler's output: ignore
        var r = Model.parseRow(line)
        if (!r) return
        root.rows = root.capRows(Model.appendRow(root.rows, r))
        root.recompute()
      }
    }
    onStarted: root.watch(sampleProc, root.sampleDeadlineSec)
    onExited: function(code, status) {
      root.unwatch()
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
    if (loadProc.running) loadProc.signal(15)
  }
}
