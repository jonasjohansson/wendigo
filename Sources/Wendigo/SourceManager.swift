import Foundation
import Combine
import CoreMedia
import CoreVideo
import AppKit
import os
import OSLog

private let logger = Logger(subsystem: "wendigo", category: "SourceManager")

enum AnySource: Hashable, Codable {
    case ndi(NDISourceInfo)
    case syphon(SyphonSourceInfo)
    case test(TestSourceConfig)

    var name: String {
        switch self {
        case .ndi(let info): return "NDI: \(info.name)"
        case .syphon(let info): return "Syphon: \(info.appName) - \(info.name)"
        case .test(let config): return "Test: \(config.label) (\(config.width)x\(config.height))"
        }
    }

    var type: String {
        switch self {
        case .ndi: return "NDI"
        case .syphon: return "Syphon"
        case .test: return "Test"
        }
    }
}

struct StreamMapping: Identifiable, Codable {
    let id: UUID
    let source: AnySource
    var streamId: String
    var isActive: Bool
    var fps: Double = 0
    var resolution: String = ""

    enum CodingKeys: String, CodingKey {
        case id, source, streamId
    }

    init(id: UUID, source: AnySource, streamId: String, isActive: Bool) {
        self.id = id
        self.source = source
        self.streamId = streamId
        self.isActive = isActive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        source = try container.decode(AnySource.self, forKey: .source)
        streamId = try container.decode(String.self, forKey: .streamId)
        isActive = false
        fps = 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(source, forKey: .source)
        try container.encode(streamId, forKey: .streamId)
    }
}

class SourceManager: ObservableObject {
    @Published var ndiSources: [NDISourceInfo] = []
    @Published var syphonSources: [SyphonSourceInfo] = []
    @Published var mappings: [StreamMapping] = []

    // Encoding settings (applied when streams are started)
    @Published var bitrateMbps: Int = 30
    @Published var keyframeInterval: Int = 1

    // Preview
    @Published var previewMappingId: UUID?
    @Published var previewImage: NSImage?
    @Published var previewResolution: String = ""
    private var lastPreviewTime: CFAbsoluteTime = 0
    private let previewInterval: CFAbsoluteTime = 1.0 / 15.0  // ~15fps preview

    private var ndiDiscovery: NDIDiscovery?
    private var syphonDiscovery: SyphonDiscovery?
    private var discoveryTimer: Timer?

    let server = WebSocketServer()

    // Per-mapping state
    private var receivers: [String: Any] = [:]       // mapping.id -> receiver
    private var encoders: [String: StreamEncoder] = [:] // mapping.id -> encoder
    private var frameCounters: [String: Int] = [:]
    private var counterLock = os_unfair_lock()
    private var frameTimers: [String: Timer] = [:]
    private var reconnectTimers: [String: Timer] = [:]
    /// Per-mapping latest pixel buffer — only the newest is encoded, preventing queue buildup
    private var latestBuffers: [String: (CVPixelBuffer, CMTime)] = [:]
    private var encodeScheduled: [String: Bool] = [:]
    private var encodeLock = os_unfair_lock()
    private let reconnectDelay: TimeInterval = 3.0

    // Persistence
    private static var mappingsFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Wendigo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mappings.json")
    }

    func startDiscovery() {
        ndiDiscovery = NDIDiscovery()
        syphonDiscovery = SyphonDiscovery()

        // Restore saved mappings and start them
        loadMappings()

        discoveryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshSources()
        }
        refreshSources()
    }

    func refreshSources() {
        if let ndi = ndiDiscovery {
            ndiSources = ndi.discoverSources()
        }
        if let syphon = syphonDiscovery {
            syphonSources = syphon.discoverSources()
        }
    }

    func addMapping(source: AnySource) {
        let mapping = StreamMapping(
            id: UUID(),
            source: source,
            streamId: slugifySource(source),
            isActive: false
        )
        mappings.append(mapping)
        saveMappings()
    }

    /// Turn "NDI: MACHINE (Arena - FLOOR)" → "arena-floor"
    private func slugifySource(_ source: AnySource) -> String {
        var name: String
        switch source {
        case .ndi(let info):
            // NDI names are "MACHINE (Source Name)" — extract the part in parens
            if let open = info.name.range(of: "("),
               let close = info.name.range(of: ")", range: open.upperBound..<info.name.endIndex) {
                name = String(info.name[open.upperBound..<close.lowerBound])
            } else {
                name = info.name
            }
        case .syphon(let info):
            name = "\(info.appName)-\(info.name)"
        case .test(let config):
            name = config.label
        }

        // Lowercase, replace spaces/special chars with hyphens, collapse multiples
        return name
            .lowercased()
            .replacingOccurrences(of: " - ", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "[^a-z0-9\\-]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    func updateStreamId(for mapping: StreamMapping, newId: String) {
        guard let idx = mappings.firstIndex(where: { $0.id == mapping.id }) else { return }
        let oldId = mappings[idx].streamId
        let trimmed = newId.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != oldId else { return }
        // Migrate cached config/keyframe and connected clients to new stream ID
        server.clearStreamCache(streamId: oldId)
        server.disconnectClients(streamId: oldId)
        mappings[idx].streamId = trimmed
        // Update encoder's broadcast target
        let key = mapping.id.uuidString
        if let encoder = encoders[key] {
            encoder.onEncodedFrame = { [weak self] type, timestamp, data in
                self?.server.broadcast(streamId: trimmed, type: type, timestamp: timestamp, data: data)
            }
        }
        updateServerStreams()
        saveMappings()
        logger.info("Stream ID changed: \(oldId) -> \(trimmed)")
    }

    /// Push current encoding settings to all active encoders.
    /// Stops the encoder session so it recreates with new settings on next frame.
    /// Clients stay connected — they receive the new config automatically.
    private func applyEncodingSettings() {
        for (_, encoder) in encoders {
            encoder.keyframeInterval = self.keyframeInterval
            encoder.bitrateMbps = self.bitrateMbps
            encoder.stop()  // session recreates on next incoming frame
        }
        // Clear cached config/keyframes so clients get fresh ones
        for mapping in mappings where mapping.isActive {
            server.clearStreamCache(streamId: mapping.streamId)
        }
        logger.info("Encoding settings updated: \(self.bitrateMbps) Mbps, keyframe every \(self.keyframeInterval) frames")
    }

    func removeMapping(_ mapping: StreamMapping) {
        stopMapping(mapping)
        mappings.removeAll { $0.id == mapping.id }
        saveMappings()
    }

    func startMapping(_ mapping: StreamMapping) {
        guard let idx = mappings.firstIndex(where: { $0.id == mapping.id }) else { return }
        let key = mapping.id.uuidString

        // Create encoder (session is lazily created on first frame to match input resolution)
        let encoder = StreamEncoder()
        encoder.keyframeInterval = keyframeInterval
        encoder.bitrateMbps = bitrateMbps
        encoder.onEncodedFrame = { [weak self] type, timestamp, data in
            self?.server.broadcast(streamId: mapping.streamId, type: type, timestamp: timestamp, data: data)
        }
        encoders[key] = encoder

        // Track FPS
        os_unfair_lock_lock(&counterLock)
        frameCounters[key] = 0
        os_unfair_lock_unlock(&counterLock)
        frameTimers[key] = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let idx = self.mappings.firstIndex(where: { $0.id == mapping.id }) else { return }
            os_unfair_lock_lock(&self.counterLock)
            let count = self.frameCounters[key] ?? 0
            self.frameCounters[key] = 0
            os_unfair_lock_unlock(&self.counterLock)
            let newFps = Double(count)
            if self.mappings[idx].fps != newFps {
                self.mappings[idx].fps = newFps
            }
            // Update resolution from encoder (cheap, once per second)
            if let encoder = self.encoders[key] {
                let res = encoder.currentResolution
                if self.mappings[idx].resolution != res {
                    self.mappings[idx].resolution = res
                }
            }
        }

        // Create receiver — only keep the latest frame, encode on a separate queue
        let frameCount = OSAllocatedUnfairLock(initialState: UInt64(0))
        let encodeQueue = DispatchQueue(label: "wendigo.encode.\(key)", qos: .userInteractive)
        switch mapping.source {
        case .ndi(let ndiSource):
            let receiver = NDIFrameReceiver()
            let mappingId = mapping.id
            receiver.onPixelBuffer = { [weak encoder, weak self] pixelBuffer in
                guard let self = self else { return }
                let count = frameCount.withLock { val -> UInt64 in let c = val; val += 1; return c }
                let pts = CMTime(value: CMTimeValue(count), timescale: 60)
                // Store latest buffer — overwrites any unprocessed frame
                self.storeAndScheduleEncode(key: key, buffer: pixelBuffer, pts: pts, encoder: encoder, encodeQueue: encodeQueue)
                os_unfair_lock_lock(&self.counterLock)
                self.frameCounters[key] = (self.frameCounters[key] ?? 0) + 1
                os_unfair_lock_unlock(&self.counterLock)
                self.capturePreviewIfNeeded(mappingId: mappingId, pixelBuffer: pixelBuffer)
            }
            receiver.onSourceStalled = { [weak self] in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.scheduleReconnect(for: mapping)
                }
            }
            receiver.connect(to: ndiSource)
            receivers[key] = receiver

        case .syphon(let syphonSource):
            guard let receiver = SyphonFrameReceiver() else { return }
            let mappingId = mapping.id
            receiver.onPixelBuffer = { [weak encoder, weak self] pixelBuffer in
                guard let self = self else { return }
                let count = frameCount.withLock { val -> UInt64 in let c = val; val += 1; return c }
                let pts = CMTime(value: CMTimeValue(count), timescale: 60)
                self.storeAndScheduleEncode(key: key, buffer: pixelBuffer, pts: pts, encoder: encoder, encodeQueue: encodeQueue)
                os_unfair_lock_lock(&self.counterLock)
                self.frameCounters[key] = (self.frameCounters[key] ?? 0) + 1
                os_unfair_lock_unlock(&self.counterLock)
                self.capturePreviewIfNeeded(mappingId: mappingId, pixelBuffer: pixelBuffer)
            }
            receiver.connect(to: syphonSource)
            receivers[key] = receiver

        case .test(let config):
            let receiver = TestSourceReceiver(config: config)
            let mappingId = mapping.id
            receiver.onPixelBuffer = { [weak encoder, weak self] pixelBuffer in
                guard let self = self else { return }
                let count = frameCount.withLock { val -> UInt64 in let c = val; val += 1; return c }
                let pts = CMTime(value: CMTimeValue(count), timescale: 60)
                self.storeAndScheduleEncode(key: key, buffer: pixelBuffer, pts: pts, encoder: encoder, encodeQueue: encodeQueue)
                os_unfair_lock_lock(&self.counterLock)
                self.frameCounters[key] = (self.frameCounters[key] ?? 0) + 1
                os_unfair_lock_unlock(&self.counterLock)
                self.capturePreviewIfNeeded(mappingId: mappingId, pixelBuffer: pixelBuffer)
            }
            receiver.start()
            receivers[key] = receiver
        }

        mappings[idx].isActive = true
        updateServerStreams()
        logger.info("Started mapping: \(mapping.source.name) -> \(mapping.streamId)")
    }

    /// Store a pixel buffer and schedule encoding if not already scheduled
    private func storeAndScheduleEncode(key: String, buffer: CVPixelBuffer, pts: CMTime, encoder: StreamEncoder?, encodeQueue: DispatchQueue) {
        os_unfair_lock_lock(&encodeLock)
        latestBuffers[key] = (buffer, pts)
        let needsSchedule = encodeScheduled[key] != true
        if needsSchedule { encodeScheduled[key] = true }
        os_unfair_lock_unlock(&encodeLock)
        if needsSchedule {
            encodeQueue.async { [weak self] in
                self?.encodeLatest(key: key, encoder: encoder)
            }
        }
    }

    /// Encode only the latest frame for a mapping, then check for a newer one
    private func encodeLatest(key: String, encoder: StreamEncoder?) {
        os_unfair_lock_lock(&encodeLock)
        guard let (buffer, pts) = latestBuffers[key] else {
            encodeScheduled[key] = false
            os_unfair_lock_unlock(&encodeLock)
            return
        }
        latestBuffers.removeValue(forKey: key)
        os_unfair_lock_unlock(&encodeLock)

        encoder?.encode(buffer, timestamp: pts)

        // Check if a newer frame arrived while we were encoding
        os_unfair_lock_lock(&encodeLock)
        let hasNext = latestBuffers[key] != nil
        os_unfair_lock_unlock(&encodeLock)

        if hasNext {
            encodeLatest(key: key, encoder: encoder)
        } else {
            os_unfair_lock_lock(&encodeLock)
            encodeScheduled[key] = false
            os_unfair_lock_unlock(&encodeLock)
        }
    }

    private func updateServerStreams() {
        var streams: [String: WebSocketServer.StreamInfo] = [:]
        for m in mappings where m.isActive {
            streams[m.streamId] = WebSocketServer.StreamInfo(
                streamId: m.streamId,
                sourceName: m.source.name,
                sourceType: m.source.type
            )
        }
        server.activeStreams = streams
    }

    func stopMapping(_ mapping: StreamMapping) {
        guard let idx = mappings.firstIndex(where: { $0.id == mapping.id }) else { return }
        let key = mapping.id.uuidString

        reconnectTimers[key]?.invalidate()
        reconnectTimers.removeValue(forKey: key)

        if let r = receivers[key] as? NDIFrameReceiver { r.disconnect() }
        if let r = receivers[key] as? SyphonFrameReceiver { r.disconnect() }
        if let r = receivers[key] as? TestSourceReceiver { r.stop() }
        receivers.removeValue(forKey: key)

        encoders[key]?.stop()
        encoders.removeValue(forKey: key)

        frameTimers[key]?.invalidate()
        frameTimers.removeValue(forKey: key)
        os_unfair_lock_lock(&counterLock)
        frameCounters.removeValue(forKey: key)
        os_unfair_lock_unlock(&counterLock)

        mappings[idx].isActive = false
        if previewMappingId == mapping.id {
            previewMappingId = nil
            previewImage = nil
            previewResolution = ""
        }
        server.clearStreamCache(streamId: mapping.streamId)
        updateServerStreams()
        logger.info("Stopped mapping: \(mapping.source.name) -> \(mapping.streamId)")
    }

    func stopAll() {
        for mapping in mappings where mapping.isActive {
            stopMapping(mapping)
        }
        discoveryTimer?.invalidate()
        server.stop()
    }

    // MARK: - Auto-reconnect

    /// Tear down the receiver for a stalled mapping and reconnect after a delay
    private func scheduleReconnect(for mapping: StreamMapping) {
        let key = mapping.id.uuidString

        // Don't stack multiple reconnect timers
        guard reconnectTimers[key] == nil else { return }
        guard mappings.contains(where: { $0.id == mapping.id && $0.isActive }) else { return }

        logger.warning("Source stalled: \(mapping.source.name) — reconnecting in \(self.reconnectDelay)s")

        // Zero FPS immediately so user sees it's down
        if let idx = mappings.firstIndex(where: { $0.id == mapping.id }) {
            mappings[idx].fps = 0
        }

        // Tear down old receiver + encoder (keep web clients connected — they handle new config)
        if let r = receivers[key] as? NDIFrameReceiver { r.disconnect() }
        if let r = receivers[key] as? SyphonFrameReceiver { r.disconnect() }
        if let r = receivers[key] as? TestSourceReceiver { r.stop() }
        receivers.removeValue(forKey: key)
        encoders[key]?.stop()
        encoders.removeValue(forKey: key)
        server.clearStreamCache(streamId: mapping.streamId)

        reconnectTimers[key] = Timer.scheduledTimer(withTimeInterval: reconnectDelay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.reconnectTimers.removeValue(forKey: key)

            // Only reconnect if the mapping still exists and is supposed to be active
            guard self.mappings.contains(where: { $0.id == mapping.id && $0.isActive }) else { return }

            logger.info("Reconnecting: \(mapping.source.name)")
            self.reconnectReceiver(for: mapping)
        }
    }

    /// Rebuild just the receiver and encoder for an existing active mapping
    private func reconnectReceiver(for mapping: StreamMapping) {
        let key = mapping.id.uuidString

        let encoder = StreamEncoder()
        encoder.keyframeInterval = keyframeInterval
        encoder.bitrateMbps = bitrateMbps
        encoder.onEncodedFrame = { [weak self] type, timestamp, data in
            self?.server.broadcast(streamId: mapping.streamId, type: type, timestamp: timestamp, data: data)
        }
        encoders[key] = encoder

        let frameCount = OSAllocatedUnfairLock(initialState: UInt64(0))
        let mappingId = mapping.id
        let encodeQueue = DispatchQueue(label: "wendigo.encode.\(key)", qos: .userInteractive)

        switch mapping.source {
        case .ndi(let ndiSource):
            let receiver = NDIFrameReceiver()
            receiver.onPixelBuffer = { [weak encoder, weak self] pixelBuffer in
                guard let self = self else { return }
                let count = frameCount.withLock { val -> UInt64 in let c = val; val += 1; return c }
                let pts = CMTime(value: CMTimeValue(count), timescale: 60)
                self.storeAndScheduleEncode(key: key, buffer: pixelBuffer, pts: pts, encoder: encoder, encodeQueue: encodeQueue)
                os_unfair_lock_lock(&self.counterLock)
                self.frameCounters[key] = (self.frameCounters[key] ?? 0) + 1
                os_unfair_lock_unlock(&self.counterLock)
                self.capturePreviewIfNeeded(mappingId: mappingId, pixelBuffer: pixelBuffer)
            }
            receiver.onSourceStalled = { [weak self] in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.scheduleReconnect(for: mapping)
                }
            }
            receiver.connect(to: ndiSource)
            receivers[key] = receiver

        case .syphon(let syphonSource):
            guard let receiver = SyphonFrameReceiver() else { return }
            receiver.onPixelBuffer = { [weak encoder, weak self] pixelBuffer in
                guard let self = self else { return }
                let count = frameCount.withLock { val -> UInt64 in let c = val; val += 1; return c }
                let pts = CMTime(value: CMTimeValue(count), timescale: 60)
                self.storeAndScheduleEncode(key: key, buffer: pixelBuffer, pts: pts, encoder: encoder, encodeQueue: encodeQueue)
                os_unfair_lock_lock(&self.counterLock)
                self.frameCounters[key] = (self.frameCounters[key] ?? 0) + 1
                os_unfair_lock_unlock(&self.counterLock)
                self.capturePreviewIfNeeded(mappingId: mappingId, pixelBuffer: pixelBuffer)
            }
            receiver.connect(to: syphonSource)
            receivers[key] = receiver

        case .test(let config):
            let receiver = TestSourceReceiver(config: config)
            receiver.onPixelBuffer = { [weak encoder, weak self] pixelBuffer in
                guard let self = self else { return }
                let count = frameCount.withLock { val -> UInt64 in let c = val; val += 1; return c }
                let pts = CMTime(value: CMTimeValue(count), timescale: 60)
                self.storeAndScheduleEncode(key: key, buffer: pixelBuffer, pts: pts, encoder: encoder, encodeQueue: encodeQueue)
                os_unfair_lock_lock(&self.counterLock)
                self.frameCounters[key] = (self.frameCounters[key] ?? 0) + 1
                os_unfair_lock_unlock(&self.counterLock)
                self.capturePreviewIfNeeded(mappingId: mappingId, pixelBuffer: pixelBuffer)
            }
            receiver.start()
            receivers[key] = receiver
        }
    }

    /// Capture a preview frame if this mapping is selected and enough time has passed
    private func capturePreviewIfNeeded(mappingId: UUID, pixelBuffer: CVPixelBuffer) {
        guard previewMappingId == mappingId else { return }
        let now = CFAbsoluteTimeGetCurrent()
        // Throttle: only convert ~10 frames per second
        guard now - lastPreviewTime > previewInterval else { return }
        lastPreviewTime = now

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let resolution = "\(width) x \(height)"

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ), let cgImage = context.makeImage() else { return }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        DispatchQueue.main.async {
            self.previewImage = image
            self.previewResolution = resolution
        }
    }

    // MARK: - Persistence

    private func saveMappings() {
        do {
            let data = try JSONEncoder().encode(mappings)
            try data.write(to: Self.mappingsFileURL, options: .atomic)
            logger.info("Saved \(self.mappings.count) mapping(s)")
        } catch {
            logger.error("Failed to save mappings: \(error)")
        }
    }

    private func loadMappings() {
        let url = Self.mappingsFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let saved = try JSONDecoder().decode([StreamMapping].self, from: data)
            for mapping in saved {
                mappings.append(mapping)
                // Don't auto-start — user adds streams manually
            }
            logger.info("Restored \(saved.count) mapping(s) (not started)")
        } catch {
            logger.error("Failed to load mappings: \(error)")
        }
    }
}
