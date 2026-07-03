import Cocoa

// Writing to a pipe whose reader (the `lp` child) has already exited would otherwise
// deliver SIGPIPE and kill us. Ignore it; POSIX write() then returns EPIPE instead.
signal(SIGPIPE, SIG_IGN)

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
