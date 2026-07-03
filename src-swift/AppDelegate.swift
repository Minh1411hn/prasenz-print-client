import Cocoa
import Foundation
import Network

// MARK: - LogManager & Unified Logging System
class LogManager {
    static let shared = LogManager()
    private let queue = DispatchQueue(label: "com.prasenz.logmanager")
    private(set) var logs = [String]()
    private let maxLogs = 200

    // MARK: New Relic log forwarding (optional; off until a license key is configured)
    private var nrLicenseKey: String?
    private var nrEndpoint = "https://log-api.newrelic.com/log/v1"
    private var nrPending = [[String: Any]]()
    private let nrMaxPending = 500          // bounded buffer — drops oldest beyond this
    private let nrBatchSize = 100           // flush early once this many are pending
    private var nrTimer: DispatchSourceTimer?
    private let nrSession = URLSession(configuration: .ephemeral)
    private let nrHostName = ProcessInfo.processInfo.hostName

    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        let logLine = "[\(timestamp)] \(message)"

        NSLog("\(message)")

        queue.async { [weak self] in
            guard let self = self else { return }
            self.logs.append(logLine)
            if self.logs.count > self.maxLogs {
                self.logs.removeFirst()
            }
            self.enqueueNewRelic(logLine)
        }
    }

    /// Enables/updates New Relic forwarding, or disables it when `licenseKey` is empty.
    func configureNewRelic(licenseKey: String, endpoint: String?) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let key = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
            self.nrLicenseKey = key.isEmpty ? nil : key
            if let ep = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines), !ep.isEmpty {
                self.nrEndpoint = ep
            }
            if self.nrLicenseKey != nil {
                self.startNewRelicTimer()
                NSLog("[NewRelic] log forwarding enabled -> \(self.nrEndpoint)")
            } else {
                self.nrTimer?.cancel()
                self.nrTimer = nil
                self.nrPending.removeAll()
            }
        }
    }

    // The methods below always run on `queue`.

    private func enqueueNewRelic(_ message: String) {
        guard nrLicenseKey != nil else { return }
        nrPending.append([
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "message": message
        ])
        if nrPending.count > nrMaxPending {
            nrPending.removeFirst(nrPending.count - nrMaxPending)
        }
        if nrPending.count >= nrBatchSize {
            flushNewRelic()
        }
    }

    private func startNewRelicTimer() {
        guard nrTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.flushNewRelic() }
        timer.resume()
        nrTimer = timer
    }

    private func flushNewRelic() {
        guard let key = nrLicenseKey, !nrPending.isEmpty,
              let url = URL(string: nrEndpoint) else { return }

        let batch = nrPending
        nrPending.removeAll(keepingCapacity: true)

        let payload: [[String: Any]] = [[
            "common": ["attributes": [
                "service": "PrasenzPrinter",
                "hostname": nrHostName,
                "version": "1.2.0"
            ]],
            "logs": batch
        ]]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "Api-Key")
        req.httpBody = body

        nrSession.dataTask(with: req) { [weak self] _, response, error in
            let ok = (response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false
            guard !ok, let self = self else { return }
            // Re-queue the failed batch (within cap) for the next flush. Use NSLog only —
            // never appLog — so a forwarding failure can't feed itself back into the queue.
            NSLog("[NewRelic] forward failed (\(error?.localizedDescription ?? "bad status")); re-queueing \(batch.count) logs")
            self.queue.async {
                self.nrPending.insert(contentsOf: batch, at: 0)
                if self.nrPending.count > self.nrMaxPending {
                    self.nrPending.removeFirst(self.nrPending.count - self.nrMaxPending)
                }
            }
        }.resume()
    }
}

func appLog(_ message: String) {
    LogManager.shared.log(message)
}

// MARK: - Thread-Safe Print Queue with Per-Printer Sub-Queues
class PrintQueue {

    /// Reject new jobs once a printer's backlog reaches this depth. Each queued job
    /// holds its full PDF in memory, so this bounds RAM under a burst of requests.
    static let maxQueueDepth = 100

    // MARK: - Per-Printer Sub-Queue (strict FIFO submission for each printer)
    private class PrinterSubQueue {
        struct Job {
            let pdfBuffer: Data
            let options: [String]
            let enqueuedAt: Date
            let completion: (Result<Void, Error>) -> Void
        }

        let printerName: String
        private let queue: DispatchQueue
        private var jobs = [Job]()
        private var activeCount = 0
        // Submit exactly one job at a time per printer so CUPS receives them in the
        // order the requests arrived. A single printer prints serially anyway, so this
        // guarantees ordering at no real throughput cost. Parallelism still happens
        // ACROSS printers, since each printer has its own sub-queue.
        private let maxConcurrent = 1
        private var lastSpawnAt: Date?

        init(printerName: String) {
            self.printerName = printerName
            self.queue = DispatchQueue(label: "com.prasenz.printqueue.\(printerName)", qos: .userInitiated)
        }

        /// Enqueues a job. Returns false synchronously if this printer's backlog is full.
        func enqueue(pdfBuffer: Data, options: [String], completion: @escaping (Result<Void, Error>) -> Void) -> Bool {
            return queue.sync {
                guard jobs.count < PrintQueue.maxQueueDepth else {
                    return false
                }
                jobs.append(Job(pdfBuffer: pdfBuffer, options: options, enqueuedAt: Date(), completion: completion))
                queue.async { self.processNextJob() }
                return true
            }
        }

        private func processNextJob() {
            dispatchPrecondition(condition: .onQueue(queue))

            guard activeCount < maxConcurrent else { return }
            guard !jobs.isEmpty else { return }

            activeCount += 1
            let job = jobs.removeFirst()

            let printProcess = Process()
            printProcess.executableURL = URL(fileURLWithPath: "/usr/bin/lp")

            // No file argument => lp reads the document from stdin, avoiding a temp-file
            // write + read + cleanup round-trip on every job.
            var arguments = ["-d", printerName]
            arguments.append(contentsOf: job.options)
            printProcess.arguments = arguments

            let inPipe = Pipe()
            printProcess.standardInput = inPipe
            let errPipe = Pipe()
            printProcess.standardError = errPipe

            // Instrumentation: how long the job waited in queue, and the gap since the
            // previous spawn for this printer. Lets us localize any "gap between prints".
            let now = Date()
            let waited = now.timeIntervalSince(job.enqueuedAt)
            let sinceLast = lastSpawnAt.map { String(format: ", %.3fs since previous spawn", now.timeIntervalSince($0)) } ?? ""
            lastSpawnAt = now
            appLog("🖨️ [PrintQueue - \(printerName)] Spawning lp (waited \(String(format: "%.3f", waited))s in queue\(sinceLast)). Backlog: \(jobs.count)")

            let startTime = Date()

            printProcess.terminationHandler = { [weak self] proc in
                guard let self = self else { return }
                let duration = Date().timeIntervalSince(startTime)

                self.queue.async {
                    self.activeCount -= 1

                    if proc.terminationStatus == 0 {
                        appLog("✅ [PrintQueue - \(self.printerName)] Spooled successfully in \(String(format: "%.3f", duration))s")
                        job.completion(.success(()))
                    } else {
                        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                        let errMsg = String(data: errData, encoding: .utf8) ?? "lp command failed"
                        appLog("❌ [PrintQueue - \(self.printerName)] Error after \(String(format: "%.3f", duration))s: \(errMsg)")
                        job.completion(.failure(NSError(domain: "PrintQueue", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errMsg])))
                    }

                    self.processNextJob()
                }
            }

            do {
                try printProcess.run()
                // Feed the PDF to lp's stdin off the serial queue so a full OS pipe buffer
                // (large PDFs) can't block job submission. POSIX write returns -1 on a broken
                // pipe (lp exited early) instead of raising; SIGPIPE is ignored at startup.
                let writeHandle = inPipe.fileHandleForWriting
                let writeFD = writeHandle.fileDescriptor
                let data = job.pdfBuffer
                DispatchQueue.global(qos: .userInitiated).async {
                    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                        guard var ptr = raw.baseAddress, raw.count > 0 else { return }
                        var remaining = raw.count
                        while remaining > 0 {
                            let n = write(writeFD, ptr, remaining)
                            if n <= 0 { break }
                            ptr = ptr.advanced(by: n)
                            remaining -= n
                        }
                    }
                    try? writeHandle.close()
                }
            } catch {
                try? inPipe.fileHandleForWriting.close()
                activeCount -= 1
                job.completion(.failure(error))
                processNextJob()
            }
        }

        var count: Int {
            var c = 0
            queue.sync { c = jobs.count }
            return c
        }
    }

    // MARK: - Manager (router distributing to sub-queue of each printer)
    private let managerQueue = DispatchQueue(label: "com.prasenz.printqueue.manager", qos: .userInitiated)
    private var subQueues = [String: PrinterSubQueue]()

    private func getOrCreateSubQueue(for printerName: String) -> PrinterSubQueue {
        managerQueue.sync {
            if let existing = subQueues[printerName] {
                return existing
            }
            let newQueue = PrinterSubQueue(printerName: printerName)
            subQueues[printerName] = newQueue
            return newQueue
        }
    }

    /// Enqueues a job for the target printer. Returns false if that printer's backlog is full.
    @discardableResult
    func enqueue(pdfBuffer: Data, targetPrinter: String, options: [String], completion: @escaping (Result<Void, Error>) -> Void) -> Bool {
        let subQueue = getOrCreateSubQueue(for: targetPrinter)
        return subQueue.enqueue(pdfBuffer: pdfBuffer, options: options, completion: completion)
    }

    var count: Int {
        managerQueue.sync {
            subQueues.values.reduce(0) { $0 + $1.count }
        }
    }
}

// MARK: - Cloudflare Tunnel subprocess manager
enum TunnelStatus: String {
    case disconnected = "disconnected"
    case connecting = "connecting"
    case connected = "connected"
    case error = "error"
}

class TunnelManager {
    private var tunnelProcess: Process?
    private let queue = DispatchQueue(label: "com.prasenz.tunnelmanager")
    
    // Status tracking
    private(set) var status: TunnelStatus = .disconnected
    private(set) var errorMessage: String? = nil
    var onStatusChange: ((TunnelStatus, String?) -> Void)?
    
    private func updateStatus(_ newStatus: TunnelStatus, errorMessage: String? = nil) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.status != newStatus || self.errorMessage != errorMessage {
                self.status = newStatus
                self.errorMessage = errorMessage
                DispatchQueue.main.async {
                    self.onStatusChange?(newStatus, errorMessage)
                }
            }
        }
    }
    
    func startTunnel(token: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            self.stopTunnelInternal()
            
            guard !token.isEmpty else {
                appLog("[TunnelManager] Cloudflare Tunnel Token is empty. Skipping tunnel start.")
                self.updateStatus(.disconnected)
                return
            }
            
            self.updateStatus(.connecting)
            
            let archName: String
            #if arch(arm64)
            archName = "cloudflared-silicon"
            #else
            archName = "cloudflared-intel"
            #endif
            
            let fileManager = FileManager.default
            var binaryURL: URL?
            
            if let url = Bundle.main.url(forResource: archName, withExtension: nil, subdirectory: "bin") {
                binaryURL = url
            } else if let url = Bundle.main.url(forResource: archName, withExtension: nil) {
                binaryURL = url
            }
            
            if binaryURL == nil {
                let path1 = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/bin/\(archName)")
                if fileManager.fileExists(atPath: path1.path) {
                    binaryURL = path1
                }
            }
            
            if binaryURL == nil, let exeURL = Bundle.main.executableURL {
                let path2 = exeURL.deletingLastPathComponent().appendingPathComponent("bin/\(archName)")
                if fileManager.fileExists(atPath: path2.path) {
                    binaryURL = path2
                }
            }
            
            if binaryURL == nil {
                let path3 = URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent("bin/\(archName)")
                if fileManager.fileExists(atPath: path3.path) {
                    binaryURL = path3
                }
            }
            
            guard let finalBinaryURL = binaryURL else {
                let err = "[TunnelManager] Critical Error: Cloudflare binary [\(archName)] not found."
                appLog(err)
                self.updateStatus(.error, errorMessage: "cloudflared executable file not found")
                return
            }
            
            appLog("[TunnelManager] Starting Cloudflare Tunnel using \(finalBinaryURL.path)...")
            
            let process = Process()
            process.executableURL = finalBinaryURL
            process.arguments = ["tunnel", "run", "--token", token]
            
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                    appLog("[Cloudflared STDOUT] \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
            
            errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                    let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    appLog("[Cloudflared STDERR] \(trimmedOutput)")
                    
                    let lower = trimmedOutput.lowercased()
                    if lower.contains("established") || lower.contains("registered") {
                        self?.updateStatus(.connected)
                    } else if lower.contains("failed") || lower.contains("error") || lower.contains("cannot") || lower.contains("unauthorized") {
                        // Only change to error if not currently connected
                        if self?.status != .connected {
                            let errMsg: String
                            if lower.contains("unauthorized") || lower.contains("token") || lower.contains("invalid") {
                                errMsg = "Invalid or expired Token"
                            } else if lower.contains("network") || lower.contains("dns") || lower.contains("dial tcp") {
                                errMsg = "Network / DNS connection error"
                            } else {
                                errMsg = "Cloudflare connection error"
                            }
                            self?.updateStatus(.error, errorMessage: errMsg)
                        }
                    }
                }
            }
            
            process.terminationHandler = { [weak self] proc in
                appLog("[TunnelManager] Cloudflare Tunnel exited with status: \(proc.terminationStatus)")
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                
                self?.queue.async {
                    self?.tunnelProcess = nil
                    self?.updateStatus(.disconnected)
                }
            }
            
            do {
                try process.run()
                self.tunnelProcess = process
                appLog("[TunnelManager] Cloudflare Tunnel subprocess launched.")
            } catch {
                let errMsg = "Failed to launch Cloudflare Tunnel: \(error.localizedDescription)"
                appLog("[TunnelManager] \(errMsg)")
                self.updateStatus(.error, errorMessage: error.localizedDescription)
            }
        }
    }
    
    func stopTunnel() {
        queue.sync {
            self.stopTunnelInternal()
            self.updateStatus(.disconnected)
        }
    }
    
    private func stopTunnelInternal() {
        guard let process = tunnelProcess, process.isRunning else {
            return
        }
        
        appLog("[TunnelManager] Stopping Cloudflare Tunnel subprocess...")
        process.terminate()
        process.waitUntilExit()
        tunnelProcess = nil
        appLog("[TunnelManager] Cloudflare Tunnel subprocess stopped.")
    }
    
    var isActive: Bool {
        var active = false
        queue.sync {
            active = tunnelProcess?.isRunning ?? false
        }
        return active
    }
}

class FlippedStackView: NSStackView {
    override var isFlipped: Bool {
        return true
    }
}

class CopyPasteTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown {
            if event.modifierFlags.contains(.command) {
                switch event.charactersIgnoringModifiers {
                case "x":
                    if let editor = self.currentEditor() {
                        editor.cut(self)
                        return true
                    }
                case "c":
                    if let editor = self.currentEditor() {
                        editor.copy(self)
                        return true
                    }
                case "v":
                    if let editor = self.currentEditor() {
                        editor.paste(self)
                        return true
                    }
                case "a":
                    if let editor = self.currentEditor() {
                        editor.selectAll(self)
                        return true
                    }
                default:
                    break
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

class CopyPasteSecureTextField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown {
            if event.modifierFlags.contains(.command) {
                switch event.charactersIgnoringModifiers {
                case "x":
                    if let editor = self.currentEditor() {
                        editor.cut(self)
                        return true
                    }
                case "c":
                    if let editor = self.currentEditor() {
                        editor.copy(self)
                        return true
                    }
                case "v":
                    if let editor = self.currentEditor() {
                        editor.paste(self)
                        return true
                    }
                case "a":
                    if let editor = self.currentEditor() {
                        editor.selectAll(self)
                        return true
                    }
                default:
                    break
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - SettingsViewController
class SettingsViewController: NSViewController {
    
    // UI Elements
    private let titleLabel = NSTextField(labelWithString: "Prasenz Print Configuration")
    
    private let tokenLabel = NSTextField(labelWithString: "CLOUDFLARE TUNNEL TOKEN")
    private let tokenField = CopyPasteSecureTextField()
    
    // Cloudflare Tunnel Status Elements
    private let tunnelStatusTitleLabel = NSTextField(labelWithString: "TUNNEL STATUS")
    private let tunnelStatusDot = NSView()
    private let tunnelStatusLabel = NSTextField(labelWithString: "Disconnected")
    private let tunnelStatusStack = NSStackView()
    
    private let portLabel = NSTextField(labelWithString: "CONNECTION PORT")
    private let portField = CopyPasteTextField()
    
    private let printerListLabel = NSTextField(labelWithString: "PRINTER LIST")
    private let printerScrollView = NSScrollView()
    private let printerListStack = FlippedStackView()
    
    private let autostartCheckbox = NSButton(checkboxWithTitle: "Start with macOS", target: nil, action: nil)
    
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    
    private let statusLabel = NSTextField(labelWithString: "")

    // New Relic log forwarding
    private let nrKeyLabel = NSTextField(labelWithString: "NEW RELIC LICENSE KEY")
    private let nrKeyField = CopyPasteSecureTextField()

    // Store reference to containerStack for full-width constraints
    private var containerStack: NSStackView!

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 410))
        self.preferredContentSize = NSSize(width: 440, height: 410)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }
    
    private func setupUI() {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        self.containerStack = stack
        
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])
        
        // Brand Color: #4E1528
        let brandColor = NSColor(red: 0x4E/255.0, green: 0x15/255.0, blue: 0x28/255.0, alpha: 1.0)
        
        // Title Styling
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = brandColor
        titleLabel.alignment = .left
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        stack.addArrangedSubview(titleLabel)
        stack.setCustomSpacing(14, after: titleLabel)
        
        // Helper to style small uppercase labels
        func styleLabel(_ label: NSTextField) {
            label.font = NSFont.systemFont(ofSize: 10, weight: .bold)
            label.textColor = .secondaryLabelColor
            label.alignment = .left
            label.isEditable = false
            label.isBordered = false
            label.drawsBackground = false
        }
        
        styleLabel(tokenLabel)
        tokenField.placeholderString = "Paste Cloudflare secure Token"
        tokenField.bezelStyle = .roundedBezel
        tokenField.heightAnchor.constraint(equalToConstant: 24).isActive = true
        
        styleLabel(portLabel)
        portField.placeholderString = "Default is 37588 if left empty"
        portField.bezelStyle = .roundedBezel
        portField.heightAnchor.constraint(equalToConstant: 24).isActive = true

        styleLabel(nrKeyLabel)
        nrKeyField.placeholderString = "Optional — forward logs to New Relic"
        nrKeyField.bezelStyle = .roundedBezel
        nrKeyField.heightAnchor.constraint(equalToConstant: 24).isActive = true

        // Add settings fields to stack
        stack.addArrangedSubview(tokenLabel)
        stack.addArrangedSubview(tokenField)
        
        // Tunnel status elements
        styleLabel(tunnelStatusTitleLabel)
        
        tunnelStatusDot.wantsLayer = true
        tunnelStatusDot.layer?.cornerRadius = 4.5
        tunnelStatusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tunnelStatusDot.widthAnchor.constraint(equalToConstant: 9),
            tunnelStatusDot.heightAnchor.constraint(equalToConstant: 9)
        ])
        
        tunnelStatusLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        tunnelStatusLabel.isEditable = false
        tunnelStatusLabel.isBordered = false
        tunnelStatusLabel.drawsBackground = false
        
        tunnelStatusStack.orientation = .horizontal
        tunnelStatusStack.alignment = .centerY
        tunnelStatusStack.spacing = 6
        tunnelStatusStack.translatesAutoresizingMaskIntoConstraints = false
        tunnelStatusStack.addArrangedSubview(tunnelStatusDot)
        tunnelStatusStack.addArrangedSubview(tunnelStatusLabel)
        
        stack.addArrangedSubview(tunnelStatusTitleLabel)
        stack.addArrangedSubview(tunnelStatusStack)
        stack.setCustomSpacing(10, after: tunnelStatusStack)
        
        stack.addArrangedSubview(portLabel)
        stack.addArrangedSubview(portField)
        stack.setCustomSpacing(10, after: portField)

        stack.addArrangedSubview(nrKeyLabel)
        stack.addArrangedSubview(nrKeyField)
        stack.setCustomSpacing(10, after: nrKeyField)

        // Printer list section
        styleLabel(printerListLabel)
        stack.addArrangedSubview(printerListLabel)
        
        // Configure printer list scroll view
        printerListStack.orientation = .vertical
        printerListStack.alignment = .leading
        printerListStack.spacing = 2
        printerListStack.translatesAutoresizingMaskIntoConstraints = false
        
        let clipView = NSClipView()
        clipView.documentView = printerListStack
        clipView.drawsBackground = false
        
        printerScrollView.contentView = clipView
        printerScrollView.hasVerticalScroller = true
        printerScrollView.hasHorizontalScroller = false
        printerScrollView.autohidesScrollers = true
        printerScrollView.drawsBackground = false
        printerScrollView.borderType = .bezelBorder
        printerScrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(printerScrollView)
        printerScrollView.heightAnchor.constraint(equalToConstant: 82).isActive = true
        stack.setCustomSpacing(10, after: printerScrollView)
        
        // Full width constraints for fields and controls
        let fullWidthViews: [NSView] = [
            titleLabel, tokenLabel, tokenField,
            tunnelStatusTitleLabel, tunnelStatusStack,
            portLabel, portField, nrKeyLabel, nrKeyField,
            printerListLabel, printerScrollView
        ]
        for v in fullWidthViews {
            v.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            v.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
        
        // Autostart checkbox
        autostartCheckbox.font = NSFont.systemFont(ofSize: 12)
        stack.addArrangedSubview(autostartCheckbox)
        stack.setCustomSpacing(12, after: autostartCheckbox)
        
        // Buttons Row
        let buttonsStack = NSStackView()
        buttonsStack.orientation = .horizontal
        buttonsStack.spacing = 10
        buttonsStack.distribution = .fillEqually
        buttonsStack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(buttonsStack)
        buttonsStack.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        buttonsStack.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        
        refreshButton.target = self
        refreshButton.action = #selector(refreshButtonClicked)
        refreshButton.bezelStyle = .rounded
        refreshButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        buttonsStack.addArrangedSubview(refreshButton)
        
        saveButton.target = self
        saveButton.action = #selector(saveButtonClicked)
        saveButton.bezelStyle = .rounded
        saveButton.bezelColor = brandColor
        saveButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        buttonsStack.addArrangedSubview(saveButton)
        
        // Status label
        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        statusLabel.textColor = .systemGreen
        statusLabel.alignment = .left
        statusLabel.isEditable = false
        statusLabel.isBordered = false
        statusLabel.drawsBackground = false
        statusLabel.cell?.wraps = true
        statusLabel.cell?.isScrollable = false
        stack.addArrangedSubview(statusLabel)
        statusLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        statusLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
    }
    
    func loadSettingsAndPrinters() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        
        // 1. Load settings
        let settings = appDelegate.readSettings()
        tokenField.stringValue = (settings["TUNNEL_TOKEN"] as? String) ?? ""
        portField.stringValue = (settings["PORT"] as? String) ?? "37588"
        nrKeyField.stringValue = (settings["NEW_RELIC_LICENSE_KEY"] as? String) ?? ""
        
        // 2. Load autostart checkbox status
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let plistURL = homeDir.appendingPathComponent("Library/LaunchAgents/com.prasenz.printagent.plist")
        let exists = FileManager.default.fileExists(atPath: plistURL.path)
        autostartCheckbox.state = exists ? .on : .off
        
        // 3. Populate printer list
        let availablePrinters = getSystemPrinters()
        populatePrinterList(availablePrinters)
        
        // 4. Update tunnel status UI immediately
        updateTunnelStatusUI(status: appDelegate.tunnelManager.status, errorMessage: appDelegate.tunnelManager.errorMessage)
        
        // 5. Register real-time update callback
        appDelegate.tunnelManager.onStatusChange = { [weak self] newStatus, errMsg in
            self?.updateTunnelStatusUI(status: newStatus, errorMessage: errMsg)
        }
        
        showStatus("Current configuration loaded.", isError: false)
    }
    
    private func populatePrinterList(_ printers: [String]) {
        // Clear existing rows
        for view in printerListStack.arrangedSubviews {
            printerListStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        
        if printers.isEmpty {
            let emptyLabel = NSTextField(labelWithString: "No printers found.")
            emptyLabel.font = NSFont.systemFont(ofSize: 12)
            emptyLabel.textColor = .secondaryLabelColor
            emptyLabel.isEditable = false
            emptyLabel.isBordered = false
            emptyLabel.drawsBackground = false
            printerListStack.addArrangedSubview(emptyLabel)
            return
        }
        
        for printerName in printers {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            
            let nameLabel = NSTextField(labelWithString: printerName)
            nameLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            nameLabel.textColor = .labelColor
            nameLabel.isEditable = false
            nameLabel.isBordered = false
            nameLabel.drawsBackground = false
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            
            let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyPrinterName(_:)))
            copyButton.bezelStyle = .inline
            copyButton.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            copyButton.setContentHuggingPriority(.required, for: .horizontal)
            copyButton.toolTip = printerName
            
            row.addArrangedSubview(nameLabel)
            row.addArrangedSubview(copyButton)
            
            row.heightAnchor.constraint(equalToConstant: 24).isActive = true
            printerListStack.addArrangedSubview(row)
            
            // Constrain row width to scroll view content width
            if let stack = self.containerStack {
                row.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 4).isActive = true
                row.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16).isActive = true
            }
        }
    }
    
    @objc private func copyPrinterName(_ sender: NSButton) {
        guard let printerName = sender.toolTip else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(printerName, forType: .string)
        showStatus("Copied: \(printerName)", isError: false)
    }
    
    private func getSystemPrinters() -> [String] {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return [] }
        var printers = [String]()
        let lpstatE = appDelegate.shell("lpstat -e").trimmingCharacters(in: .whitespacesAndNewlines)
        if !lpstatE.isEmpty {
            printers = lpstatE.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            let lpstatP = appDelegate.shell("lpstat -p")
            printers = lpstatP.components(separatedBy: .newlines)
                .filter { $0.hasPrefix("printer") }
                .compactMap { line in
                    let parts = line.split(separator: " ")
                    if parts.count > 1 {
                        return String(parts[1])
                    }
                    return nil
                }
        }
        return printers
    }
    
    @objc private func refreshButtonClicked() {
        loadSettingsAndPrinters()
        showStatus("Printer list refreshed.", isError: false)
    }
    
    @objc private func saveButtonClicked() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        
        let tunnelToken = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let nrKey = nrKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        var portVal = portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if portVal.isEmpty {
            portVal = "37588"
        }

        // Validate port
        guard let portNum = UInt16(portVal), portNum >= 1024 else {
            showStatus("Error: Printing port must be a number from 1024 to 65535.", isError: true)
            return
        }

        // Preserve advanced keys not exposed in the UI (e.g. a custom New Relic endpoint).
        let existing = appDelegate.readSettings()
        let nrEndpoint = (existing["NEW_RELIC_ENDPOINT"] as? String) ?? ""

        let newSettings: [String: Any] = [
            "TUNNEL_TOKEN": tunnelToken,
            "PORT": String(portNum),
            "NEW_RELIC_LICENSE_KEY": nrKey,
            "NEW_RELIC_ENDPOINT": nrEndpoint
        ]

        if appDelegate.writeSettings(newSettings) {
            // Apply New Relic log forwarding immediately
            LogManager.shared.configureNewRelic(licenseKey: nrKey, endpoint: nrEndpoint)

            // Apply autostart setting
            let autostartEnabled = autostartCheckbox.state == .on
            let (autostartSuccess, autostartMessage) = appDelegate.setAutostartEnabled(autostartEnabled)
            
            // Restart Native HTTP Server dynamically on the new port!
            appDelegate.startHttpServer(port: portNum)
            
            // Restart Cloudflare tunnel subprocess
            appDelegate.tunnelManager.startTunnel(token: tunnelToken)
            
            if autostartSuccess {
                showStatus("Configuration saved & started successfully!", isError: false)
            } else {
                showStatus("Configuration saved but autostart error: \(autostartMessage)", isError: true)
            }
        } else {
            showStatus("Error: Cannot save settings.json file", isError: true)
        }
    }
    
    private func showStatus(_ message: String, isError: Bool) {
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? .systemRed : .systemGreen
        
        // Auto-fade status after 5 seconds
        let currentString = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            if self?.statusLabel.stringValue == currentString {
                self?.statusLabel.stringValue = ""
            }
        }
    }
    
    func updateTunnelStatusUI(status: TunnelStatus, errorMessage: String? = nil) {
        let dotColor: NSColor
        let statusText: String
        let textColor: NSColor
        
        switch status {
        case .disconnected:
            dotColor = .systemGray
            statusText = "Disconnected"
            textColor = .secondaryLabelColor
        case .connecting:
            dotColor = .systemOrange
            statusText = "Connecting..."
            textColor = .systemOrange
        case .connected:
            dotColor = .systemGreen
            statusText = "Connected successfully"
            textColor = .systemGreen
        case .error:
            dotColor = .systemRed
            statusText = errorMessage ?? "Connection error"
            textColor = .systemRed
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.tunnelStatusDot.layer?.backgroundColor = dotColor.cgColor
            self.tunnelStatusLabel.stringValue = statusText
            self.tunnelStatusLabel.textColor = textColor
        }
    }
}

// MARK: - AppDelegate
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    
    var statusItem: NSStatusItem!
    var httpServer: HttpServer?
    let tunnelManager = TunnelManager()
    let printQueue = PrintQueue()
    let appStartTime = Date()
    
    // Popover for the Settings panel
    lazy var popover: NSPopover = {
        let popover = NSPopover()
        let settingsVC = SettingsViewController()
        popover.contentViewController = settingsVC
        popover.contentSize = NSSize(width: 440, height: 410)
        popover.behavior = .transient
        popover.delegate = self
        return popover
    }()
    
    private var popoverTransientCloseTime: Date?
    
    // Custom context menu for right-click with exactly TWO items
    lazy var contextMenu: NSMenu = {
        let menu = NSMenu()
        
        let openSettingsItem = NSMenuItem(title: "Open settings", action: #selector(openSettingsMenuClicked), keyEquivalent: "s")
        openSettingsItem.target = self
        menu.addItem(openSettingsItem)
        
        let terminateItem = NSMenuItem(title: "Exit", action: #selector(terminateApp), keyEquivalent: "q")
        terminateItem.target = self
        menu.addItem(terminateItem)
        
        return menu
    }()
    
    func startHttpServer(port: UInt16) {
        if httpServer != nil {
            httpServer?.stop()
            httpServer = nil
        }
        
        do {
            httpServer = HttpServer(port: port, handler: { [weak self] req in
                guard let self = self else {
                    return HttpResponse(status: 500, statusText: "Internal Server Error", contentType: "application/json", headers: [:], body: Data())
                }
                return self.routeHandler(request: req)
            })
            try httpServer?.start()
            NSLog("[HTTP] Server successfully started on port \(port)")
        } catch {
            NSLog("CRITICAL: Failed to start HTTP server on port \(port): \(error.localizedDescription)")
            showAlert(title: "Server Startup Error", message: "Cannot listen on port \(port): \(error.localizedDescription)")
        }
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        let settings = readSettings()

        // Forward logs to New Relic if a license key is configured (no-op otherwise)
        LogManager.shared.configureNewRelic(
            licenseKey: (settings["NEW_RELIC_LICENSE_KEY"] as? String) ?? "",
            endpoint: settings["NEW_RELIC_ENDPOINT"] as? String
        )

        // Start custom light HTTP Server dynamically on configured port
        let portVal = (settings["PORT"] as? String) ?? "37588"
        let portNum = UInt16(portVal) ?? 37588
        startHttpServer(port: portNum)
        
        // Start Tunnel Subprocess if token is set
        if let token = settings["TUNNEL_TOKEN"] as? String, !token.isEmpty {
            tunnelManager.startTunnel(token: token)
        }
        
        // Registers status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if #available(macOS 11.0, *) {
                if let symbolImage = NSImage(systemSymbolName: "printer.fill", accessibilityDescription: "Printer") {
                    symbolImage.isTemplate = true
                    button.image = symbolImage
                } else {
                    button.title = "🖨️"
                }
            } else {
                button.title = "🖨️"
            }
            
            button.target = self
            button.action = #selector(statusBarButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        httpServer?.stop()
        tunnelManager.stopTunnel()
    }
    
    @objc func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover(sender)
            return
        }
        
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }
    
    func showContextMenu() {
        if let button = statusItem.button {
            contextMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }
    
    @objc func openSettingsMenuClicked() {
        if let button = statusItem.button {
            togglePopover(button)
        }
    }
    
    @objc func terminateApp() {
        httpServer?.stop()
        tunnelManager.stopTunnel()
        
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let plistURL = homeDir.appendingPathComponent("Library/LaunchAgents/com.prasenz.printagent.plist")
        if FileManager.default.fileExists(atPath: plistURL.path) {
            _ = shell("launchctl unload \"\(plistURL.path)\"")
        }
        
        NSApp.terminate(nil)
    }
    
    // MARK: - Popover Management
    func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            closePopover(sender)
        } else {
            if let closeTime = popoverTransientCloseTime, Date().timeIntervalSince(closeTime) < 0.25 {
                popoverTransientCloseTime = nil
                return
            }
            showPopover(sender)
        }
    }
    
    func showPopover(_ sender: AnyObject?) {
        if let button = statusItem.button {
            if let settingsVC = popover.contentViewController as? SettingsViewController {
                settingsVC.loadSettingsAndPrinters()
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    
    func closePopover(_ sender: AnyObject?) {
        popover.performClose(sender)
    }
    
    func popoverWillClose(_ notification: Notification) {
        popoverTransientCloseTime = Date()
    }
    
    // MARK: - Configuration Path & Settings Utilities
    func getConfigURL() -> URL {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let appConfigDir = homeDir.appendingPathComponent(".prasenz-printer")
        
        // Create directory if it doesn't exist
        try? fileManager.createDirectory(at: appConfigDir, withIntermediateDirectories: true)
        
        return appConfigDir.appendingPathComponent("settings.json")
    }
    
    func readSettings() -> [String: Any] {
        let url = getConfigURL()
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                return json
            }
        }
        
        let defaultSettings: [String: Any] = [
            "TUNNEL_TOKEN": "",
            "PORT": "37588",
            "NEW_RELIC_LICENSE_KEY": "",
            "NEW_RELIC_ENDPOINT": ""
        ]
        
        let dir = url.deletingLastPathComponent()
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        if let jsonData = try? JSONSerialization.data(withJSONObject: defaultSettings, options: [.prettyPrinted]) {
            try? jsonData.write(to: url)
        }
        return defaultSettings
    }
    
    func writeSettings(_ dict: [String: Any]) -> Bool {
        let url = getConfigURL()
        let fileManager = FileManager.default
        let dir = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let jsonData = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
            try jsonData.write(to: url, options: [.atomic])
            return true
        } catch {
            NSLog("Failed to write settings: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - Autostart / Launchctl plist utilities
    func setAutostartEnabled(_ enabled: Bool) -> (Bool, String) {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let launchAgentsDir = homeDir.appendingPathComponent("Library/LaunchAgents")
        let plistURL = launchAgentsDir.appendingPathComponent("com.prasenz.printagent.plist")
        let fileManager = FileManager.default
        
        if enabled {
            do {
                if !fileManager.fileExists(atPath: launchAgentsDir.path) {
                    try fileManager.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
                }
                
                let plistContent = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>Label</key>
                    <string>com.prasenz.printagent</string>
                    <key>ProgramArguments</key>
                    <array>
                        <string>/Applications/PrasenzPrinter.app/Contents/MacOS/PrasenzPrinter</string>
                    </array>
                    <key>RunAtLoad</key>
                    <true/>
                    <key>KeepAlive</key>
                    <false/>
                    <key>StandardOutPath</key>
                    <string>/tmp/prasenz_print_agent.log</string>
                    <key>StandardErrorPath</key>
                    <string>/tmp/prasenz_print_agent_err.log</string>
                </dict>
                </plist>
                """
                
                try plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
                _ = shell("launchctl load \"\(plistURL.path)\"")
                return (true, "Start with macOS enabled!")
            } catch {
                return (false, "Error: \(error.localizedDescription)")
            }
        } else {
            do {
                if fileManager.fileExists(atPath: plistURL.path) {
                    _ = shell("launchctl unload \"\(plistURL.path)\"")
                    try fileManager.removeItem(at: plistURL)
                    return (true, "Start with macOS disabled!")
                } else {
                    return (true, "No service running.")
                }
            } catch {
                return (false, "Error: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Shell execution helper
    func shell(_ command: String) -> String {
        let task = Process()
        let pipe = Pipe()
        
        task.standardOutput = pipe
        task.standardError = pipe
        task.arguments = ["-c", command]
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output
            }
        } catch {
            NSLog("Shell execution failed: \(error.localizedDescription)")
        }
        return ""
    }
    
    // MARK: - HTTP API Route Handler
    func routeHandler(request: HttpRequest) -> HttpResponse {
        let method = request.method.uppercased()
        let path = request.path
        
        switch (method, path) {
        case ("GET", "/health"):
            let archStr: String
            #if arch(arm64)
            archStr = "arm64"
            #else
            archStr = "x86_64"
            #endif
            
            let uptime = Int(Date().timeIntervalSince(appStartTime))
            let dict: [String: Any] = [
                "status": "ok",
                "version": "1.2.0",
                "arch": archStr,
                "uptime": uptime,
                "queueLength": printQueue.count,
                "tunnelActive": tunnelManager.status == .connected,
                "tunnelStatus": tunnelManager.status.rawValue,
                "tunnelErrorMessage": tunnelManager.errorMessage ?? ""
            ]
            
            if let jsonData = try? JSONSerialization.data(withJSONObject: dict, options: []),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                return HttpResponse(status: 200, statusText: "OK", contentType: "application/json", headers: [:], body: Data(jsonString.utf8))
            }
            return HttpResponse(status: 500, statusText: "Internal Server Error", contentType: "application/json", headers: [:], body: Data("{\"error\":\"Serialization error\"}".utf8))
            
        case ("POST", "/print"):
            guard let targetPrinter = request.headers["x-printer-name"],
                  !targetPrinter.isEmpty else {
                return HttpResponse(status: 400, statusText: "Bad Request", contentType: "application/json", headers: [:], body: Data("{\"error\":\"Missing x-printer-name header\"}".utf8))
            }
            
            if request.body.isEmpty {
                return HttpResponse(status: 400, statusText: "Bad Request", contentType: "application/json", headers: [:], body: Data("{\"error\":\"Input PDF data is empty\"}".utf8))
            }
            
            let printOptionsHeader = request.headers["x-print-options"] ?? "-o fit-to-page"
            let options = printOptionsHeader.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            
            appLog("📥 Received print data for printer [\(targetPrinter)] (\(Double(request.body.count) / 1024.0) KB) with options \(options). Enqueuing...")

            let accepted = printQueue.enqueue(pdfBuffer: request.body, targetPrinter: targetPrinter, options: options) { result in
                switch result {
                case .success:
                    appLog("✅ [PrintQueue] Print successful for printer [\(targetPrinter)]")
                case .failure(let error):
                    appLog("❌ [PrintQueue] Print failed for printer [\(targetPrinter)]: \(error.localizedDescription)")
                }
            }

            if !accepted {
                appLog("⚠️ [PrintQueue] Backlog full for printer [\(targetPrinter)] (\(PrintQueue.maxQueueDepth) jobs). Rejecting with 503.")
                return HttpResponse(status: 503, statusText: "Service Unavailable", contentType: "application/json", headers: [:], body: Data("{\"error\":\"Print queue is full, try again shortly\"}".utf8))
            }

            return HttpResponse(status: 200, statusText: "OK", contentType: "application/json", headers: [:], body: Data("{\"success\":true,\"message\":\"Successfully enqueued print job\"}".utf8))
            
        default:
            return HttpResponse(status: 404, statusText: "Not Found", contentType: "application/json", headers: [:], body: Data("{\"error\":\"Not Found\"}".utf8))
        }
    }
    
    // MARK: - Dialog Alerts
    func showAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.window.level = .floating
            alert.runModal()
        }
    }
}
