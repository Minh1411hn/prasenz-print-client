import Cocoa

// Check if another instance of PrasenzPrinter is already running
let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.prasenz.printagent"
let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
if runningApps.filter({ $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }).count > 0 {
    NSLog("Another instance of PrasenzPrinter is already running. Exiting.")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
