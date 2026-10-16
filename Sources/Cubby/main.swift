import AppKit

if CommandLine.arguments.contains("--self-test") { SelfTest.run() }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
