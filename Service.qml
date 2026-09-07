import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Headless service: whenever the Omarchy theme changes, push the theme's
// keyboard.rgb color to a wired Keychron keyboard over the VIA raw-HID protocol.
//
//  - Color.accent changes at the applyTheme IPC (START of omarchy-theme-set), so it
//    is the theme-change signal. Watching keyboard.rgb itself would miss switches:
//    omarchy-theme-set flips the current/theme symlink and the previously watched
//    file never changes.
//  - The "armed" guard skips the initial value on shell (re)start: the keyboard
//    already holds the color in onboard memory, and re-applying on every restart
//    would write its flash for nothing.
//
// All reading, validation and HID I/O live in the helper, which takes no arguments,
// touches no network and writes no files. It is internally deadlined at 10s; the
// 20s TERM + 2s KILL here is the backstop for a wedged HID open.
Item {
  id: root
  property bool armed: false
  property string lastAccent: ""
  property bool pending: false
  property string errBuf: ""
  readonly property string helperPath:
    Qt.resolvedUrl("bin/omakeychron-apply.py").toString().replace(/^file:\/\//, "")

  function log(m) { console.log("[omakeychron] " + String(m).slice(0, 512)) }

  function requestApply() {
    if (proc.running) { root.pending = true; return }
    root.errBuf = ""
    proc.running = true
  }

  Connections {
    target: Color
    function onAccentChanged() {
      var a = String(Color.accent)
      if (!root.armed) { root.armed = true; root.lastAccent = a; return }
      if (a === root.lastAccent) return
      root.lastAccent = a
      root.requestApply()
    }
  }

  Process {
    id: proc
    // -I: isolated interpreter, environment hooks like PYTHONPATH ignored.
    command: ["/usr/bin/python3", "-I", root.helperPath]
    stdout: SplitParser { splitMarker: ""; onRead: function (chunk) { /* helper is silent on success */ } }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function (chunk) {
        // journald via console.log, capped; never a file, never a Text sink.
        if (root.errBuf.length < 4096) root.errBuf += String(chunk).slice(0, 4096 - root.errBuf.length)
      }
    }
    onStarted: deadline.start()
    onExited: function (code, status) {
      deadline.stop()
      kill9.stop()
      if (code !== 0) root.log("apply failed (" + code + "): " + root.errBuf)
      root.errBuf = ""
      if (root.pending) { root.pending = false; root.requestApply() }
    }
  }

  Timer { id: deadline; interval: 20000; onTriggered: { root.log("helper deadline, TERM"); proc.signal(15); kill9.start() } }
  Timer { id: kill9; interval: 2000; onTriggered: proc.signal(9) }
  Component.onDestruction: { if (proc.running) proc.signal(15) }

  Component.onCompleted: {
    root.armed = true
    root.lastAccent = String(Color.accent)
    root.log("loaded, waiting for theme changes")
  }
}
