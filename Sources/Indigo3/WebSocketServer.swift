import Foundation
import Network

class WebSocketServer: ObservableObject {
    private var listener: NWListener?
    @Published var clientCounts: [String: Int] = [:]  // streamId -> count

    private var connections: [String: [NWConnection]] = [:]  // streamId -> connections
    private let queue = DispatchQueue(label: "indigo3.ws.server")

    // Cached latest config (SPS/PPS) per stream for new client init
    private var latestConfig: [String: Data] = [:]
    private var latestKeyframe: [String: (UInt64, Data)] = [:]

    // Active stream metadata (set by SourceManager)
    var activeStreams: [String: StreamInfo] = [:]

    struct StreamInfo {
        let streamId: String
        let sourceName: String
        let sourceType: String
    }

    func start(port: UInt16 = 9000) throws {
        let params = NWParameters(tls: nil)
        let wsOptions = NWProtocolWebSocket.Options()
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("WebSocket server ready on port \(port)")
            case .failed(let error):
                print("WebSocket server failed: \(error)")
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
        connection.start(queue: queue)

        // Listen for initial text message with stream ID
        receiveStreamId(connection)
    }

    private func receiveStreamId(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self = self else { return }

            if let error = error {
                connection.cancel()
                return
            }

            // Parse stream ID from text message
            var streamId = "default"
            if let content = content, let text = String(data: content, encoding: .utf8) {
                streamId = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // Discovery: respond with stream list and close
            if streamId == "__list" {
                self.sendStreamList(to: connection)
                return
            }

            self.addClient(connection, streamId: streamId)

            // Send cached config + keyframe so decoder can initialize immediately
            if let config = self.latestConfig[streamId] {
                self.sendFrame(to: connection, type: 0x00, timestamp: 0, data: config)
            }
            if let (ts, keyframe) = self.latestKeyframe[streamId] {
                self.sendFrame(to: connection, type: 0x01, timestamp: ts, data: keyframe)
            }

            // Keep listening for messages (e.g. ping/pong, close)
            self.listenForMessages(connection, streamId: streamId)
        }
    }

    private func listenForMessages(_ connection: NWConnection, streamId: String) {
        connection.receiveMessage { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                self?.removeClient(connection, streamId: streamId)
                return
            }
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
        connections[streamId]?.removeAll { $0 === connection }
        connection.cancel()
        let count = connections[streamId]?.count ?? 0
        DispatchQueue.main.async {
            self.clientCounts[streamId] = count
        }
    }

    /// Broadcast encoded frame to all clients on a stream
    func broadcast(streamId: String, type: UInt8, timestamp: UInt64, data: Data) {
        // Cache config and keyframes for late-joining clients
        if type == 0x00 {
            latestConfig[streamId] = data
        } else if type == 0x01 {
            latestKeyframe[streamId] = (timestamp, data)
        }

        guard let clients = connections[streamId] else { return }

        for connection in clients {
            sendFrame(to: connection, type: type, timestamp: timestamp, data: data)
        }
    }

    private func sendFrame(to connection: NWConnection, type: UInt8, timestamp: UInt64, data: Data) {
        // Header: [type(1)] [timestamp(8)] [data...]
        var frame = Data(capacity: 9 + data.count)
        frame.append(type)
        var ts = timestamp.bigEndian
        frame.append(Data(bytes: &ts, count: 8))
        frame.append(data)

        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(content: frame, contentContext: context, completion: .idempotent)
    }

    private func sendStreamList(to connection: NWConnection) {
        // Build JSON: [{ "streamId": "stream1", "name": "NDI: ...", "type": "NDI" }, ...]
        let list = activeStreams.values.map { info in
            "{\"streamId\":\"\(info.streamId)\",\"name\":\"\(info.sourceName)\",\"type\":\"\(info.sourceType)\"}"
        }
        let json = "[\(list.joined(separator: ","))]"
        let data = json.data(using: .utf8) ?? Data()

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "list", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    func stop() {
        listener?.cancel()
        for (_, clients) in connections {
            for c in clients { c.cancel() }
        }
        connections.removeAll()
    }

    deinit { stop() }
}
