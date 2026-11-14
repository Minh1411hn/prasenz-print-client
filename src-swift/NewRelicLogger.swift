import Foundation

/// Ships app logs to New Relic via the Log API (US endpoint).
///
/// Designed to be performance-safe on customer machines:
/// - Log entries are buffered in memory and shipped in **batches** on a
///   background queue, so the print path is never blocked (the `/print`
///   handler already returns immediately and prints asynchronously).
/// - Flushing happens on a timer, or early once the batch grows large.
/// - The pending buffer is **capped**; oldest entries are dropped when the
///   network is down so an outage can't grow memory unbounded.
/// - Fail-soft: network/serialization errors are swallowed and never
///   propagate back into application logic.
final class NewRelicLogger {
    static let shared = NewRelicLogger()

    // US Log API endpoint (see plan: account is in the US region).
    private let endpoint = URL(string: "https://log-api.newrelic.com/log/v1")!
    private let serviceName = "prasenz-print-client"

    // Tuning knobs
    private let flushInterval: TimeInterval = 5.0
    private let batchThreshold = 50   // flush early once this many entries are pending
    private let maxBuffer = 500       // cap; drop oldest when offline/backed up

    private let queue = DispatchQueue(label: "com.prasenz.newrelic")
    private var pending = [[String: Any]]()
    private var timer: DispatchSourceTimer?

    private var licenseKey = ""
    private var hostname = ""
    private var version = ""

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    private init() {}

    /// Enable/refresh the forwarder. Safe to call repeatedly (e.g. after Save).
    /// An empty license key turns the feature off.
    func configure(licenseKey: String, hostname: String, version: String) {
        queue.async {
            self.licenseKey = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
            self.hostname = hostname
            self.version = version

            if self.licenseKey.isEmpty {
                self.stopTimer()
            } else {
                self.startTimer()
            }
        }
    }

    /// Buffer one log entry. No-op when no license key is configured.
    func enqueue(level: String, message: String, reqId: String?) {
        queue.async {
            guard !self.licenseKey.isEmpty else { return }

            var attrs: [String: Any] = [
                "service.name": self.serviceName,
                "hostname": self.hostname,
                "level": level,
                "version": self.version
            ]
            if let reqId = reqId, !reqId.isEmpty {
                attrs["p-req-id"] = reqId
            }

            let entry: [String: Any] = [
                "timestamp": Int(Date().timeIntervalSince1970 * 1000),
                "message": message,
                "attributes": attrs
            ]

            self.pending.append(entry)
            self.trimBuffer()

            if self.pending.count >= self.batchThreshold {
                self.flushLocked()
            }
        }
    }

    // MARK: - Internal (all executed on `queue`)

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        t.setEventHandler { [weak self] in self?.flushLocked() }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func trimBuffer() {
        if pending.count > maxBuffer {
            pending.removeFirst(pending.count - maxBuffer)
        }
    }

    private func flushLocked() {
        guard !licenseKey.isEmpty, !pending.isEmpty else { return }

        let batch = pending
        // New Relic Logs API accepts a top-level JSON array of log entries.
        guard let body = try? JSONSerialization.data(withJSONObject: batch, options: []) else {
            pending.removeAll()   // unserializable payload: drop rather than loop forever
            return
        }
        pending.removeAll()

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(licenseKey, forHTTPHeaderField: "Api-Key")
        req.httpBody = body

        let task = session.dataTask(with: req) { [weak self] _, response, error in
            guard let self = self else { return }

            let ok: Bool
            if let http = response as? HTTPURLResponse {
                ok = (200...299).contains(http.statusCode)
            } else {
                ok = false
            }

            // Fail-soft: on failure, re-buffer this batch to retry on the next
            // flush (still bounded by maxBuffer). NSLog only, never appLog, to
            // avoid a feedback loop back into this logger.
            if !ok || error != nil {
                self.queue.async {
                    self.pending.insert(contentsOf: batch, at: 0)
                    self.trimBuffer()
                }
            }
        }
        task.resume()
    }
}
