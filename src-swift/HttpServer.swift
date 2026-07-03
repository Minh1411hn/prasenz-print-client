import Foundation
import Network

// MARK: - HTTP Request / Response models
struct HttpRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct HttpResponse {
    let status: Int
    let statusText: String
    let contentType: String
    let headers: [String: String]
    let body: Data
}

// MARK: - Custom HTTP Server
class HttpServer {
    let port: UInt16
    let routeHandler: (String, String, [String: String], Data) -> (Int, [String: String], Data)
    private var listener: NWListener?
    private var activeConnections = [NWConnection]()
    private let connectionQueue = DispatchQueue(label: "com.prasenz.httpserver.connection")

    /// Reject a request body larger than this before buffering it in memory.
    private let maxBodySize = 25 * 1024 * 1024
    /// Drop a connection that stalls mid-request (slow-loris) or sits idle on keep-alive.
    private let readTimeout: TimeInterval = 30
    
    /// Primary initializer using the streamlined routeHandler closure mapping parameters and returning status, headers, and body.
    init(port: UInt16, routeHandler: @escaping (String, String, [String: String], Data) -> (Int, [String: String], Data)) {
        self.port = port
        self.routeHandler = routeHandler
    }
    
    /// Convenience initializer preserving compatibility with the original AppDelegate handler interface.
    convenience init(port: UInt16, handler: @escaping (HttpRequest) -> HttpResponse) {
        self.init(port: port, routeHandler: { method, path, headers, body in
            let req = HttpRequest(method: method, path: path, headers: headers, body: body)
            let res = handler(req)
            
            // Reconstruct headers dictionary including Content-Type
            var resHeaders = res.headers
            resHeaders["Content-Type"] = res.contentType
            return (res.status, resHeaders, res.body)
        })
    }
    
    func start() throws {
        let parameters = NWParameters.tcp
        if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOptions.version = .any
        }
        
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "HttpServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port"])
        }
        
        let listener = try NWListener(using: parameters, on: nwPort)
        self.listener = listener
        
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                appLog("HttpServer running on port \(self.port)")
            case .failed(let error):
                appLog("HttpServer listener failed with error: \(error)")
            default:
                break
            }
        }
        
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        
        listener.start(queue: DispatchQueue.global(qos: .userInitiated))
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        connectionQueue.sync {
            for connection in activeConnections {
                connection.cancel()
            }
            activeConnections.removeAll()
        }
        appLog("HttpServer stopped.")
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connectionQueue.sync {
            activeConnections.append(connection)
        }
        
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.connectionQueue.async {
                    self?.activeConnections.removeAll(where: { $0 === connection })
                }
            default:
                break
            }
        }
        
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
        readRequest(connection: connection, accumulatedData: Data())
    }
    
    private func readRequest(connection: NWConnection, accumulatedData: Data) {
        // Idle/slow-loris guard: if no further data arrives within readTimeout, close it.
        // Re-armed on every chunk and on every kept-alive request, so it also reaps idle
        // keep-alive connections.
        let timeout = DispatchWorkItem { [weak connection] in
            appLog("Connection idle; closing.")
            connection?.cancel()
        }
        connectionQueue.asyncAfter(deadline: .now() + readTimeout, execute: timeout)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            timeout.cancel()
            guard let self = self else { return }

            if let error = error {
                appLog("Connection read error: \(error)")
                connection.cancel()
                return
            }

            var newData = accumulatedData
            if let data = data {
                newData.append(data)
            }

            if let headerEndRange = newData.range(of: Data([13, 10, 13, 10])) ?? newData.range(of: Data([10, 10])) {
                let headersData = newData.subdata(in: 0..<headerEndRange.lowerBound)
                guard let headersString = String(data: headersData, encoding: .utf8) else {
                    connection.cancel()
                    return
                }

                let lines = headersString.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                guard let requestLine = lines.first else {
                    connection.cancel()
                    return
                }

                let reqLineParts = requestLine.split(separator: " ").map(String.init)
                guard reqLineParts.count >= 2 else {
                    connection.cancel()
                    return
                }

                let method = reqLineParts[0]
                let path = reqLineParts[1]

                var headers = [String: String]()
                for line in lines.dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
                    if parts.count == 2 {
                        let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        let val = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        headers[key] = val
                    }
                }

                let contentLength = Int(headers["content-length"] ?? "0") ?? 0
                let headerLength = headerEndRange.upperBound

                // Reject an oversized body before accumulating it in memory.
                if contentLength > self.maxBodySize {
                    let body = Data("{\"error\":\"Request body too large\"}".utf8)
                    self.sendResponse(connection: connection, status: 413, headers: [:], body: body, keepAlive: false, completion: nil)
                    return
                }

                let totalExpectedLength = headerLength + contentLength

                if newData.count >= totalExpectedLength {
                    let body = newData.subdata(in: headerLength..<totalExpectedLength)
                    // Bytes past this request belong to the next (pipelined) request on a
                    // kept-alive connection; carry them into the next read.
                    let leftover = newData.count > totalExpectedLength
                        ? newData.subdata(in: totalExpectedLength..<newData.count)
                        : Data()

                    // Call the streamlined routeHandler closure mapping parameters and returning (status, headers, body)
                    let (status, responseHeaders, responseBody) = self.routeHandler(method, path, headers, body)
                    let keepAlive = self.shouldKeepAlive(headers)

                    self.sendResponse(connection: connection, status: status, headers: responseHeaders, body: responseBody, keepAlive: keepAlive) {
                        if keepAlive {
                            self.readRequest(connection: connection, accumulatedData: leftover)
                        } else {
                            connection.cancel()
                        }
                    }
                } else {
                    if isComplete {
                        connection.cancel()
                    } else {
                        self.readRequest(connection: connection, accumulatedData: newData)
                    }
                }
            } else {
                if isComplete {
                    connection.cancel()
                } else {
                    self.readRequest(connection: connection, accumulatedData: newData)
                }
            }
        }
    }

    /// HTTP/1.1 keeps the connection alive by default unless the client requests close.
    private func shouldKeepAlive(_ headers: [String: String]) -> Bool {
        if let conn = headers["connection"]?.lowercased() {
            return conn != "close"
        }
        return true
    }

    private func sendResponse(connection: NWConnection, status: Int, headers: [String: String], body: Data, keepAlive: Bool, completion: (() -> Void)?) {
        var statusText = "OK"
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 403: statusText = "Forbidden"
        case 404: statusText = "Not Found"
        case 408: statusText = "Request Timeout"
        case 413: statusText = "Payload Too Large"
        case 500: statusText = "Internal Server Error"
        case 503: statusText = "Service Unavailable"
        default: statusText = "OK"
        }

        var responseString = "HTTP/1.1 \(status) \(statusText)\r\n"

        // Add content length and connection header
        responseString += "Content-Length: \(body.count)\r\n"
        responseString += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n"

        // Add headers from routeHandler response
        var headersToSend = headers
        if headersToSend.keys.first(where: { $0.lowercased() == "content-type" }) == nil {
            headersToSend["Content-Type"] = "application/json"
        }

        for (key, val) in headersToSend {
            responseString += "\(key): \(val)\r\n"
        }
        responseString += "\r\n"

        guard let headerData = responseString.data(using: .utf8) else {
            connection.cancel()
            return
        }

        var fullData = headerData
        fullData.append(body)

        connection.send(content: fullData, completion: .contentProcessed({ error in
            if let error = error {
                appLog("Connection send error: \(error)")
                connection.cancel()
                return
            }
            if let completion = completion {
                completion()
            } else if !keepAlive {
                connection.cancel()
            }
        }))
    }
}
