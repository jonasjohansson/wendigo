import Foundation
import Combine
import CoreMedia
import CoreVideo
import AppKit
import os

enum AnySource: Hashable {
    case ndi(NDISourceInfo)
    case syphon(SyphonSourceInfo)

    var name: String {
        switch self {
        case .ndi(let info): return "NDI: \(info.name)"
        case .syphon(let info): return "Syphon: \(info.appName) - \(info.name)"
        }
    }

    var type: String {
        switch self {
        case .ndi: return "NDI"
        case .syphon: return "Syphon"
        }
    }
}

struct StreamMapping: Identifiable {
    let id: UUID
    let source: AnySource
    var streamId: String
    var isActive: Bool
    var fps: Double = 0
}

class SourceManager: ObservableObject {
    @Published var ndiSources: [NDISourceInfo] = []
    @Published var syphonSources: [SyphonSourceInfo] = []
    @Published var mappings: [StreamMapping] = []

    // Preview
    @Published var previewMappingId: UUID?
    @Published var previewImage: NSImage?
    @Published var previewResolution: String = ""
    private var lastPreviewTime: UInt64 = 0
    private let previewIntervalNs: UInt64 = 100_000_000  // ~10fps

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


    func startDiscovery() {
        ndiDiscovery = NDIDiscovery()
        syphonDiscovery = SyphonDiscovery()

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
        startMapping(mapping)
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

    func removeMapping(_ mapping: StreamMapping) {
        stopMapping(mapping)
        mappings.removeAll { $0.id == mapping.id }
    }

    func startMapping(_ mapping: StreamMapping) {
        guard let idx = mappings.firstIndex(where: { $0.id == mapping.id }) else { return }
        let key = mapping.id.uuidString

        // Create encoder (session is lazily created on first frame to match input resolution)
        let encoder = StreamEncoder()
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
            self.mappings[idx].fps = Double(count)
        }

        // Create receiver
        let frameCount = OSAllocatedUnfairLock(initialState: UInt64(0))
        switch mapping.source {
        case .ndi(let ndiSource):
            let receiver = NDIFrameReceiver()
            let mappingId = mapping.id
            receiver.onPixelBuffer = { [weak encoder, weak self] pixelBuffer in
                guard let self = self else { return }
                let count = frameCount.withLock { val -> UInt64 in let c = val; val += 1; return c }
                let pts = CMTime(value: CMTimeValue(count), timescale: 30)
                encoder?.encode(pixelBuffer, timestamp: pts)
                os_unfair_lock_lock(&self.counterLock)
                self.frameCounters[key] = (self.frameCounters[key] ?? 0) + 1
                os_unfair_lock_unlock(&self.counterLock)
                self.capturePreviewIfNeeded(mappingId: mappingId, pixelBuffer: pixelBuffer)
            }
            receiver.connect(to: ndiSource)
            receivers[key] = receiver

        case .syphon(let syphonSource):
            guard let receiver = SyphonFrameReceiver() else { return }
            let mappingId = mapping.id
            receiver.onPixelBuffer = { [weak encoder, weak self] pixelBuffer in
                guard let self = self else { return }
                let count = frameCount.withLock { val -> UInt64 in let c = val; val += 1; return c }
                let pts = CMTime(value: CMTimeValue(count), timescale: 30)
                encoder?.encode(pixelBuffer, timestamp: pts)
                os_unfair_lock_lock(&self.counterLock)
                self.frameCounters[key] = (self.frameCounters[key] ?? 0) + 1
                os_unfair_lock_unlock(&self.counterLock)
                self.capturePreviewIfNeeded(mappingId: mappingId, pixelBuffer: pixelBuffer)
            }
            receiver.connect(to: syphonSource)
            receivers[key] = receiver
        }

        mappings[idx].isActive = true
        updateServerStreams()
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

        if let r = receivers[key] as? NDIFrameReceiver { r.disconnect() }
        if let r = receivers[key] as? SyphonFrameReceiver { r.disconnect() }
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
    }

    func stopAll() {
        for mapping in mappings where mapping.isActive {
            stopMapping(mapping)
        }
        discoveryTimer?.invalidate()
        server.stop()
    }

    /// Capture a preview frame if this mapping is selected and enough time has passed
    private func capturePreviewIfNeeded(mappingId: UUID, pixelBuffer: CVPixelBuffer) {
        guard previewMappingId == mappingId else { return }
        let now = mach_absolute_time()
        // Throttle: only convert ~10 frames per second
        guard now - lastPreviewTime > previewIntervalNs else { return }
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
}
