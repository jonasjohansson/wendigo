import Foundation
import Network
import OSLog

private let logger = Logger(subsystem: "wendigo", category: "WebSocket")

class WebSocketServer: ObservableObject {
    private var listener: NWListener?
    @Published var clientCounts: [String: Int] = [:]  // streamId -> count

    private var connections: [String: [NWConnection]] = [:]  // streamId -> connections
    private var pendingSendCounts: [ObjectIdentifier: Int] = [:]  // per-connection pending sends
    private let maxPendingSends = 3
    private let queue = DispatchQueue(label: "wendigo.ws.server")
    private let handshakeTimeout: TimeInterval = 5.0
    private var pingTimers: [ObjectIdentifier: DispatchSourceTimer] = [:]
    private var connectionStreamIds: [ObjectIdentifier: String] = [:]  // track which stream each connection belongs to

    // Cached latest config (SPS/PPS) per stream for new client init
    private var latestConfig: [String: Data] = [:]
    private var latestKeyframe: [String: (UInt64, Data)] = [:]

    // Active stream metadata (set by SourceManager)
    private var _activeStreams: [String: StreamInfo] = [:]
    var activeStreams: [String: StreamInfo] {
        get { queue.sync { _activeStreams } }
        set { queue.async { [weak self] in self?._activeStreams = newValue } }
    }

    struct StreamInfo {
        let streamId: String
        let sourceName: String
        let sourceType: String
    }

    func start(port: UInt16 = 9000) throws {
        let params = NWParameters(tls: nil)
        let wsOptions = NWProtocolWebSocket.Options()
        // Increase WebSocket message size limit for large keyframes
        wsOptions.maximumMessageSize = 16 * 1024 * 1024  // 16MB
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                logger.info("WebSocket server ready on port \(port)")
            case .failed(let error):
                logger.error("WebSocket server failed: \(error)")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener?.start(queue: queue)
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let connId = ObjectIdentifier(connection)

        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                break
            case .failed(let error):
                logger.warning("[DISCONNECT:state-failed] \(String(describing: connId).suffix(6), privacy: .public): \(error)")
                self.queue.async {
                    if let streamId = self.connectionStreamIds[connId] {
                        self.removeClient(connection, streamId: streamId)
                    }
                }
            case .cancelled:
                // Connection was cancelled — clean up if still tracked
                self.queue.async {
                    if let streamId = self.connectionStreamIds[connId] {
                        self.cleanupConnection(connId, streamId: streamId)
                    }
                }
            default:
                break
            }
        }
        connection.start(queue: queue)

        // Set up handshake timeout
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + handshakeTimeout)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let isRegistered = self.connectionStreamIds[connId] != nil
            if !isRegistered {
                logger.warning("Handshake timeout — closing idle connection")
                connection.cancel()
            }
            self.handshakeTimers.removeValue(forKey: connId)
        }
        handshakeTimers[connId] = timer
        timer.resume()

        receiveStreamId(connection)
    }

    private var handshakeTimers: [ObjectIdentifier: DispatchSourceTimer] = [:]

    private func receiveStreamId(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self = self else { return }

            let connId = ObjectIdentifier(connection)
            self.handshakeTimers[connId]?.cancel()
            self.handshakeTimers.removeValue(forKey: connId)

            if let error = error {
                logger.warning("Handshake receive error: \(error)")
                connection.cancel()
                return
            }

            var streamId = "default"
            if let content = content, let text = String(data: content, encoding: .utf8) {
                streamId = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if streamId == "__list" {
                self.sendStreamList(to: connection)
                return
            }

            logger.info("[CONNECT] \(streamId, privacy: .public)")

            // Track this connection's stream ID for state change cleanup
            self.connectionStreamIds[connId] = streamId

            // Send cached config + keyframe BEFORE adding to broadcast list
            if let config = self.latestConfig[streamId] {
                self.sendInitialFrame(to: connection, type: 0x00, timestamp: 0, data: config)
            }
            if let (ts, keyframe) = self.latestKeyframe[streamId] {
                logger.info("Sending cached keyframe to \(streamId): \(keyframe.count) bytes")
                self.sendInitialFrame(to: connection, type: 0x01, timestamp: ts, data: keyframe)
            }

            self.addClient(connection, streamId: streamId)
            self.startPingTimer(for: connection, streamId: streamId)
            self.listenForMessages(connection, streamId: streamId)
        }
    }

    private func listenForMessages(_ connection: NWConnection, streamId: String) {
        connection.receiveMessage { [weak self] content, context, isComplete, error in
            if let error = error {
                logger.warning("[DISCONNECT:listen-error] \(streamId, privacy: .public): \(error)")
                self?.removeClient(connection, streamId: streamId)
                return
            }
            // Note: isComplete means "message is complete", NOT "connection is closing"
            // For WebSocket, every message has isComplete=true — just keep listening
            self?.listenForMessages(connection, streamId: streamId)
        }
    }

    private func addClient(_ connection: NWConnection, streamId: String) {
        connections[streamId, default: []].append(connection)
        let count = connections[streamId]?.count ?? 0
        DispatchQueue.main.async {
            self.clientCounts[streamId] = count
        }
    }

    private func removeClient(_ connection: NWConnection, streamId: String) {
        let connId = ObjectIdentifier(connection)
        let wasTracked = connections[streamId]?.contains(where: { $0 === connection }) ?? false
        if !wasTracked { return }  // already removed

        logger.warning("[REMOVE] \(streamId, privacy: .public) state=\(String(describing: connection.state), privacy: .public)")

        connections[streamId]?.removeAll { $0 === connection }
        cleanupConnection(connId, streamId: streamId)
        connection.cancel()
    }

    private func cleanupConnection(_ connId: ObjectIdentifier, streamId: String) {
        pendingSendCounts.removeValue(forKey: connId)
        connectionStreamIds.removeValue(forKey: connId)
        pingTimers[connId]?.cancel()
        pingTimers.removeValue(forKey: connId)
        let count = connections[streamId]?.count ?? 0
        DispatchQueue.main.async {
            self.clientCounts[streamId] = count
        }
    }

    /// Send WebSocket ping every 30 seconds to detect dead connections
    private func startPingTimer(for connection: NWConnection, streamId: String) {
        let connId = ObjectIdentifier(connection)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard connection.state == .ready else {
                self.removeClient(connection, streamId: streamId)
                return
            }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
            metadata.setPongHandler(self.queue) { error in
                if let error = error {
                    logger.warning("[DISCONNECT:pong-failed] \(streamId, privacy: .public): \(error)")
                    self.removeClient(connection, streamId: streamId)
                }
            }
            let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
            connection.send(content: Data(), contentContext: context, completion: .contentProcessed({ error in
                if let error = error {
                    logger.warning("[DISCONNECT:ping-failed] \(streamId, privacy: .public): \(error)")
                    self.removeClient(connection, streamId: streamId)
                }
            }))
        }
        pingTimers[connId] = timer
        timer.resume()
    }

    /// Broadcast encoded frame to all clients on a stream
    func broadcast(streamId: String, type: UInt8, timestamp: UInt64, data: Data) {
        queue.async { [weak self] in
            guard let self = self else { return }

            // Cache config and keyframes for late-joining clients
            if type == 0x00 {
                self.latestConfig[streamId] = data
            } else if type == 0x01 {
                self.latestKeyframe[streamId] = (timestamp, data)
            }

            guard let clients = self.connections[streamId], !clients.isEmpty else { return }

            // Pre-build the frame once for all clients
            var frame = Data(capacity: 9 + data.count)
            frame.append(type)
            var ts = timestamp.bigEndian
            frame.append(Data(bytes: &ts, count: 8))
            frame.append(data)

            for connection in clients {
                let connId = ObjectIdentifier(connection)
                guard connection.state == .ready else { continue }
                let pending = self.pendingSendCounts[connId, default: 0]
                if pending >= self.maxPendingSends {
                    continue  // drop frame
                }
                self.pendingSendCounts[connId] = pending + 1
                self.sendFrame(to: connection, frame: frame, connId: connId)
            }
        }
    }

    /// Send a single frame to a specific connection (used for initial config/keyframe on join)
    private func sendInitialFrame(to connection: NWConnection, type: UInt8, timestamp: UInt64, data: Data) {
        var frame = Data(capacity: 9 + data.count)
        frame.append(type)
        var ts = timestamp.bigEndian
        frame.append(Data(bytes: &ts, count: 8))
        frame.append(data)

        let connId = ObjectIdentifier(connection)
        pendingSendCounts[connId] = (pendingSendCounts[connId] ?? 0) + 1
        sendFrame(to: connection, frame: frame, connId: connId)
    }

    private func sendFrame(to connection: NWConnection, frame: Data, connId: ObjectIdentifier) {
        guard connection.state == .ready else {
            pendingSendCounts[connId] = 0
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(content: frame, contentContext: context, completion: .contentProcessed({ [weak self] error in
            guard let self = self else { return }
            if let error = error {
                logger.debug("Send error for \(String(describing: connId).suffix(6)): \(error)")
                self.pendingSendCounts[connId] = 0
            } else {
                self.pendingSendCounts[connId] = max(0, (self.pendingSendCounts[connId] ?? 1) - 1)
            }
        }))
    }

    private func sendStreamList(to connection: NWConnection) {
        let list = _activeStreams.values.map { info in
            ["streamId": info.streamId, "name": info.sourceName, "type": info.sourceType]
        }
        let data = (try? JSONSerialization.data(withJSONObject: Array(list))) ?? Data()

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "list", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    func clearStreamCache(streamId: String) {
        queue.async { [weak self] in
            self?.latestConfig.removeValue(forKey: streamId)
            self?.latestKeyframe.removeValue(forKey: streamId)
        }
    }

    func disconnectClients(streamId: String) {
        queue.async { [weak self] in
            guard let self = self, let clients = self.connections[streamId] else { return }
            logger.info("Disconnecting \(clients.count) client(s) on stream \(streamId) for encoder reset")
            for connection in clients {
                let connId = ObjectIdentifier(connection)
                self.cleanupConnection(connId, streamId: streamId)
                connection.cancel()
            }
            self.connections[streamId] = []
        }
    }

    func stop() {
        listener?.cancel()
        queue.sync {
            for (_, clients) in connections {
                for c in clients { c.cancel() }
            }
            connections.removeAll()
            pendingSendCounts.removeAll()
            connectionStreamIds.removeAll()
            latestConfig.removeAll()
            latestKeyframe.removeAll()
            _activeStreams.removeAll()
            for timer in pingTimers.values { timer.cancel() }
            pingTimers.removeAll()
            for timer in handshakeTimers.values { timer.cancel() }
            handshakeTimers.removeAll()
        }
        DispatchQueue.main.async {
            self.clientCounts.removeAll()
        }
        logger.info("WebSocket server stopped")
    }

    deinit {
        listener?.cancel()
    }
}
