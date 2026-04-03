# indigo3 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a macOS Swift app that receives 5 NDI/Syphon sources and streams them as low-latency H.264 over WebSocket to elverket's Three.js browser app.

**Architecture:** Single-process Swift app: NDI/Syphon receivers → CVPixelBuffer → VideoToolbox H.264 hardware encode → raw NALUs over WebSocket. Browser decodes with WebCodecs API and uploads VideoFrames as WebGL textures.

**Tech Stack:** Swift 5.9, SwiftUI, VideoToolbox, Network.framework, Metal, NDI SDK, Syphon, WebCodecs (browser)

---

### Task 1: Project Scaffold

**Files:**
- Create: `Package.swift`
- Create: `Sources/Indigo3/Indigo3App.swift`
- Copy: `Sources/CSyphon/` (from indigo2)
- Copy: `Sources/CNDI/` (from indigo2)

**Step 1: Copy C wrapper libraries from indigo2**

```bash
cp -r /Users/jonas/Documents/GitHub/org/jonasjohansson/indigo2/macos/Sources/CSyphon \
  /Users/jonas/Documents/GitHub/org/jonasjohansson/indigo3/Sources/CSyphon
cp -r /Users/jonas/Documents/GitHub/org/jonasjohansson/indigo2/macos/Sources/CNDI \
  /Users/jonas/Documents/GitHub/org/jonasjohansson/indigo3/Sources/CNDI
```

**Step 2: Create Package.swift**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Indigo3",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CSyphon",
            path: "Sources/CSyphon",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .define("GL_SILENCE_DEPRECATION"),
                .unsafeFlags(["-fmodules", "-fcxx-modules", "-Wno-deprecated-declarations", "-include", "SyphonPrefix.h"])
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("IOSurface"),
                .linkedFramework("OpenGL"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .target(
            name: "CNDI",
            path: "Sources/CNDI",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I/Library/NDI SDK for Apple/include"])
            ],
            linkerSettings: [
                .unsafeFlags(["-L/Library/NDI SDK for Apple/lib/macOS", "-lndi", "-Xlinker", "-rpath", "-Xlinker", "/Library/NDI SDK for Apple/lib/macOS"])
            ]
        ),
        .executableTarget(
            name: "Indigo3",
            dependencies: ["CSyphon", "CNDI"],
            path: "Sources/Indigo3"
        )
    ]
)
```

**Step 3: Create minimal app entry point**

```swift
// Sources/Indigo3/Indigo3App.swift
import SwiftUI

@main
struct Indigo3App: App {
    var body: some Scene {
        WindowGroup {
            Text("Indigo3")
                .frame(width: 600, height: 400)
        }
    }
}
```

**Step 4: Verify it builds**

Run: `cd /Users/jonas/Documents/GitHub/org/jonasjohansson/indigo3 && swift build`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add Package.swift Sources/
git commit -m "feat: project scaffold with CSyphon and CNDI wrappers"
```

---

### Task 2: NDI Receiver (adapted from indigo2)

**Files:**
- Create: `Sources/Indigo3/NDIReceiver.swift`

**Step 1: Create NDIReceiver with CVPixelBuffer output**

Adapted from indigo2's NDIReceiver.swift — removes IOSurface dependency, outputs CVPixelBuffer instead.

```swift
// Sources/Indigo3/NDIReceiver.swift
import Foundation
import CoreVideo
import CNDI

struct NDISourceInfo: Identifiable, Hashable {
    let id = UUID()
    let name: String
}

class NDIDiscovery {
    private var findInstance: NDIlib_find_instance_t?

    init() {
        NDIlib_initialize()
        var settings = NDIlib_find_create_t(
            show_local_sources: true,
            p_groups: nil,
            p_extra_ips: nil
        )
        findInstance = NDIlib_find_create_v2(&settings)
    }

    deinit {
        if let find = findInstance {
            NDIlib_find_destroy(find)
        }
    }

    func discoverSources() -> [NDISourceInfo] {
        guard let find = findInstance else { return [] }
        var count: UInt32 = 0
        guard let sources = NDIlib_find_get_current_sources(find, &count) else { return [] }
        return (0..<Int(count)).map { i in
            NDISourceInfo(name: String(cString: sources[i].p_ndi_name))
        }
    }
}

class NDIFrameReceiver {
    private var recvInstance: NDIlib_recv_instance_t?
    private var isRunning = false
    private let receiveQueue = DispatchQueue(label: "indigo3.ndi.receive", qos: .userInteractive)

    var onPixelBuffer: ((CVPixelBuffer) -> Void)?

    func connect(to source: NDISourceInfo) {
        var ndiSource = NDIlib_source_t()
        ndiSource.p_ndi_name = (source.name as NSString).utf8String

        var settings = NDIlib_recv_create_v3_t()
        settings.source_to_connect_to = ndiSource
        settings.color_format = NDIlib_recv_color_format_BGRX_BGRA
        settings.bandwidth = NDIlib_recv_bandwidth_highest
        settings.allow_video_fields = true
        settings.p_ndi_recv_name = ("Indigo3" as NSString).utf8String

        recvInstance = NDIlib_recv_create_v3(&settings)
        guard recvInstance != nil else { return }

        isRunning = true
        receiveQueue.async { [weak self] in
            self?.receiveLoop()
        }
    }

    private func receiveLoop() {
        guard let recv = recvInstance else { return }

        while isRunning {
            var videoFrame = NDIlib_video_frame_v2_t()
            var audioFrame = NDIlib_audio_frame_v2_t()
            var metadataFrame = NDIlib_metadata_frame_t()

            let frameType = NDIlib_recv_capture_v2(recv, &videoFrame, &audioFrame, &metadataFrame, 100)

            switch frameType {
            case NDIlib_frame_type_video:
                if let data = videoFrame.p_data {
                    let width = Int(videoFrame.xres)
                    let height = Int(videoFrame.yres)
                    let stride = Int(videoFrame.line_stride_in_bytes)

                    var pixelBuffer: CVPixelBuffer?
                    CVPixelBufferCreateWithBytes(
                        nil, width, height,
                        kCVPixelFormatType_32BGRA,
                        data, stride,
                        nil, nil, nil,
                        &pixelBuffer
                    )
                    if let pb = pixelBuffer {
                        onPixelBuffer?(pb)
                    }
                }
                NDIlib_recv_free_video_v2(recv, &videoFrame)

            case NDIlib_frame_type_audio:
                NDIlib_recv_free_audio_v2(recv, &audioFrame)

            case NDIlib_frame_type_metadata:
                NDIlib_recv_free_metadata(recv, &metadataFrame)

            default:
                break
            }
        }
    }

    func disconnect() {
        isRunning = false
        if let recv = recvInstance {
            NDIlib_recv_destroy(recv)
            recvInstance = nil
        }
    }

    deinit { disconnect() }
}
```

**Step 2: Verify it builds**

Run: `cd /Users/jonas/Documents/GitHub/org/jonasjohansson/indigo3 && swift build`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/Indigo3/NDIReceiver.swift
git commit -m "feat: NDI receiver with CVPixelBuffer output"
```

---

### Task 3: Syphon Receiver (adapted from indigo2)

**Files:**
- Create: `Sources/Indigo3/SyphonReceiver.swift`

**Step 1: Create SyphonReceiver with CVPixelBuffer output**

Adapted from indigo2 — converts Metal texture to CVPixelBuffer for the encoder.

```swift
// Sources/Indigo3/SyphonReceiver.swift
import Foundation
import AppKit
import Metal
import CoreVideo
import CSyphon

struct SyphonSourceInfo: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let appName: String
}

class SyphonDiscovery {
    func discoverSources() -> [SyphonSourceInfo] {
        guard let servers = SyphonServerDirectory.shared().servers as? [[String: Any]] else { return [] }
        return servers.compactMap { server in
            let name = server[SyphonServerDescriptionNameKey as String] as? String ?? "Unnamed"
            let appName = server[SyphonServerDescriptionAppNameKey as String] as? String ?? "Unknown"
            return SyphonSourceInfo(name: name, appName: appName)
        }
    }
}

class SyphonFrameReceiver {
    private var client: SyphonMetalClient?
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    // Reusable pixel buffer pool for GPU → CVPixelBuffer conversion
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0

    var onPixelBuffer: ((CVPixelBuffer) -> Void)?

    init?(device: MTLDevice? = nil) {
        guard let dev = device ?? MTLCreateSystemDefaultDevice() else { return nil }
        guard let queue = dev.makeCommandQueue() else { return nil }
        self.device = dev
        self.commandQueue = queue
    }

    func connect(to source: SyphonSourceInfo) {
        guard let servers = SyphonServerDirectory.shared().servers as? [[String: Any]] else { return }

        let matching = servers.first { server in
            let name = server[SyphonServerDescriptionNameKey as String] as? String ?? ""
            let app = server[SyphonServerDescriptionAppNameKey as String] as? String ?? ""
            return name == source.name && app == source.appName
        }

        guard let serverDesc = matching else { return }

        client = SyphonMetalClient(
            serverDescription: serverDesc,
            device: device,
            options: nil,
            newFrameHandler: { [weak self] (client: SyphonMetalClient) in
                guard let self = self, let texture = client.newFrameImage() else { return }
                self.textureToPixelBuffer(texture)
            }
        )
    }

    private func textureToPixelBuffer(_ texture: any MTLTexture) {
        let width = texture.width
        let height = texture.height

        // Recreate pool if dimensions changed
        if width != poolWidth || height != poolHeight {
            let attrs: [String: Any] = [
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pixelBufferPool)
            poolWidth = width
            poolHeight = height
        }

        guard let pool = pixelBufferPool else { return }

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pb = pixelBuffer else { return }

        CVPixelBufferLockBaseAddress(pb, [])
        let dest = CVPixelBufferGetBaseAddress(pb)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let region = MTLRegion(origin: MTLOrigin(), size: MTLSize(width: width, height: height, depth: 1))
        texture.getBytes(dest, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
        CVPixelBufferUnlockBaseAddress(pb, [])

        onPixelBuffer?(pb)
    }

    func disconnect() {
        client?.stop()
        client = nil
    }

    deinit { disconnect() }
}
```

**Step 2: Verify it builds**

Run: `cd /Users/jonas/Documents/GitHub/org/jonasjohansson/indigo3 && swift build`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/Indigo3/SyphonReceiver.swift
git commit -m "feat: Syphon receiver with Metal to CVPixelBuffer conversion"
```

---

### Task 4: H.264 Stream Encoder (VideoToolbox)

**Files:**
- Create: `Sources/Indigo3/StreamEncoder.swift`

**Step 1: Create StreamEncoder wrapping VTCompressionSession**

```swift
// Sources/Indigo3/StreamEncoder.swift
import Foundation
import VideoToolbox
import CoreMedia

class StreamEncoder {
    private var session: VTCompressionSession?
    private var sps: Data?
    private var pps: Data?

    /// Called with encoded NALU data: (type, timestamp_us, data)
    /// type: 0x00 = SPS/PPS config, 0x01 = keyframe, 0x02 = delta
    var onEncodedFrame: ((UInt8, UInt64, Data) -> Void)?

    private let width: Int32
    private let height: Int32

    init(width: Int32 = 1920, height: Int32 = 1080) {
        self.width = width
        self.height = height
    }

    func start() -> Bool {
        let callback: VTCompressionOutputCallback = { refcon, _, status, flags, sampleBuffer in
            guard status == noErr, let sampleBuffer = sampleBuffer, let refcon = refcon else { return }
            let encoder = Unmanaged<StreamEncoder>.fromOpaque(refcon).takeUnretainedValue()
            encoder.handleEncodedFrame(sampleBuffer)
        }

        var status = VTCompressionSessionCreate(
            allocator: nil,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else { return false }

        // Low-latency real-time encoding
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 8_000_000 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_High_AutoLevel)

        status = VTCompressionSessionPrepareToEncodeFrames(session)
        return status == noErr
    }

    func encode(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard let session = session else { return }
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: timestamp,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    private func handleEncodedFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampUs = UInt64(CMTimeGetSeconds(timestamp) * 1_000_000)

        // Check if keyframe
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        var isKeyframe = true
        if let attachments = attachments, CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
            var notSync: CFBoolean?
            if CFDictionaryGetValueIfPresent(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(), nil) {
                isKeyframe = false
            }
        }

        // Extract SPS/PPS from keyframes
        if isKeyframe {
            if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                extractParameterSets(formatDesc)
            }
        }

        // Extract NALU data
        var totalLength = 0
        CMBlockBufferGetDataLength(dataBuffer)
        var dataPointer: UnsafeMutablePointer<Int8>?
        var length = 0
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let ptr = dataPointer else { return }
        let data = Data(bytes: ptr, count: length)
        let type: UInt8 = isKeyframe ? 0x01 : 0x02
        onEncodedFrame?(type, timestampUs, data)
    }

    private func extractParameterSets(_ formatDesc: CMFormatDescription) {
        var spsSize = 0, spsCount = 0
        var ppsSize = 0, ppsCount = 0
        var spsPtr: UnsafePointer<UInt8>?
        var ppsPtr: UnsafePointer<UInt8>?

        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc, parameterSetIndex: 0,
            parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil
        )
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc, parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: &ppsCount, nalUnitHeaderLengthOut: nil
        )

        if let spsPtr = spsPtr, let ppsPtr = ppsPtr {
            let newSps = Data(bytes: spsPtr, count: spsSize)
            let newPps = Data(bytes: ppsPtr, count: ppsSize)

            // Only send if changed
            if newSps != sps || newPps != pps {
                sps = newSps
                pps = newPps
                // Pack SPS + PPS together: [spsLen(4)] [sps] [ppsLen(4)] [pps]
                var configData = Data()
                var sLen = UInt32(spsSize).bigEndian
                var pLen = UInt32(ppsSize).bigEndian
                configData.append(Data(bytes: &sLen, count: 4))
                configData.append(newSps)
                configData.append(Data(bytes: &pLen, count: 4))
                configData.append(newPps)
                onEncodedFrame?(0x00, 0, configData)
            }
        }
    }

    var latestConfig: Data? {
        guard let sps = sps, let pps = pps else { return nil }
        var configData = Data()
        var sLen = UInt32(sps.count).bigEndian
        var pLen = UInt32(pps.count).bigEndian
        configData.append(Data(bytes: &sLen, count: 4))
        configData.append(sps)
        configData.append(Data(bytes: &pLen, count: 4))
        configData.append(pps)
        return configData
    }

    func stop() {
        if let session = session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    deinit { stop() }
}
```

**Step 2: Verify it builds**

Run: `cd /Users/jonas/Documents/GitHub/org/jonasjohansson/indigo3 && swift build`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/Indigo3/StreamEncoder.swift
git commit -m "feat: H.264 hardware encoder via VideoToolbox"
```

---

### Task 5: WebSocket Server (Network.framework)

**Files:**
- Create: `Sources/Indigo3/WebSocketServer.swift`

**Step 1: Create WebSocket server with path-based routing**

```swift
// Sources/Indigo3/WebSocketServer.swift
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

        // Extract stream ID from path via WebSocket metadata
        // Clients connect to ws://host:9000 and send stream ID in first text message
        // Or we parse from the HTTP upgrade path

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
        DispatchQueue.main.async {
            self.clientCounts[streamId] = self.connections[streamId]?.count ?? 0
        }
    }

    private func removeClient(_ connection: NWConnection, streamId: String) {
        connections[streamId]?.removeAll { $0 === connection }
        connection.cancel()
        DispatchQueue.main.async {
            self.clientCounts[streamId] = self.connections[streamId]?.count ?? 0
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

    func stop() {
        listener?.cancel()
        for (_, clients) in connections {
            for c in clients { c.cancel() }
        }
        connections.removeAll()
    }

    deinit { stop() }
}
```

**Step 2: Verify it builds**

Run: `cd /Users/jonas/Documents/GitHub/org/jonasjohansson/indigo3 && swift build`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/Indigo3/WebSocketServer.swift
git commit -m "feat: WebSocket server with stream routing and late-join support"
```

---

### Task 6: SourceManager (orchestrator)

**Files:**
- Create: `Sources/Indigo3/SourceManager.swift`

**Step 1: Create SourceManager that wires receivers → encoder → WebSocket**

```swift
// Sources/Indigo3/SourceManager.swift
import Foundation
import Combine
import CoreMedia

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
    var bitrate: Double = 0
}

class SourceManager: ObservableObject {
    @Published var ndiSources: [NDISourceInfo] = []
    @Published var syphonSources: [SyphonSourceInfo] = []
    @Published var mappings: [StreamMapping] = []

    private var ndiDiscovery: NDIDiscovery?
    private var syphonDiscovery: SyphonDiscovery?
    private var discoveryTimer: Timer?

    let server = WebSocketServer()

    // Per-mapping state
    private var receivers: [String: Any] = [:]       // mapping.id -> receiver
    private var encoders: [String: StreamEncoder] = [] // mapping.id -> encoder
    private var frameCounters: [String: Int] = [:]
    private var frameTimers: [String: Timer] = [:]

    private var streamCounter = 0

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
        streamCounter += 1
        let mapping = StreamMapping(
            id: UUID(),
            source: source,
            streamId: "stream\(streamCounter)",
            isActive: false
        )
        mappings.append(mapping)
        startMapping(mapping)
    }

    func removeMapping(_ mapping: StreamMapping) {
        stopMapping(mapping)
        mappings.removeAll { $0.id == mapping.id }
    }

    func startMapping(_ mapping: StreamMapping) {
        guard let idx = mappings.firstIndex(where: { $0.id == mapping.id }) else { return }
        let key = mapping.id.uuidString

        // Create encoder
        let encoder = StreamEncoder()
        guard encoder.start() else {
            print("Failed to start encoder for \(mapping.streamId)")
            return
        }
        encoder.onEncodedFrame = { [weak self] type, timestamp, data in
            self?.server.broadcast(streamId: mapping.streamId, type: type, timestamp: timestamp, data: data)
        }
        encoders[key] = encoder

        // Track FPS
        frameCounters[key] = 0
        frameTimers[key] = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let idx = self.mappings.firstIndex(where: { $0.id == mapping.id }) else { return }
            self.mappings[idx].fps = Double(self.frameCounters[key] ?? 0)
            self.frameCounters[key] = 0
        }

        // Create receiver
        var frameCount: UInt64 = 0
        switch mapping.source {
        case .ndi(let ndiSource):
            let receiver = NDIFrameReceiver()
            receiver.onPixelBuffer = { [weak encoder, weak self] pixelBuffer in
                let pts = CMTime(value: CMTimeValue(frameCount), timescale: 30)
                frameCount += 1
                encoder?.encode(pixelBuffer, timestamp: pts)
                self?.frameCounters[key] = (self?.frameCounters[key] ?? 0) + 1
            }
            receiver.connect(to: ndiSource)
            receivers[key] = receiver

        case .syphon(let syphonSource):
            guard let receiver = SyphonFrameReceiver() else { return }
            receiver.onPixelBuffer = { [weak encoder, weak self] pixelBuffer in
                let pts = CMTime(value: CMTimeValue(frameCount), timescale: 30)
                frameCount += 1
                encoder?.encode(pixelBuffer, timestamp: pts)
                self?.frameCounters[key] = (self?.frameCounters[key] ?? 0) + 1
            }
            receiver.connect(to: syphonSource)
            receivers[key] = receiver
        }

        mappings[idx].isActive = true
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
        frameCounters.removeValue(forKey: key)

        mappings[idx].isActive = false
    }

    func stopAll() {
        for mapping in mappings where mapping.isActive {
            stopMapping(mapping)
        }
        discoveryTimer?.invalidate()
        server.stop()
    }
}
```

**Step 2: Verify it builds**

Run: `cd /Users/jonas/Documents/GitHub/org/jonasjohansson/indigo3 && swift build`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/Indigo3/SourceManager.swift
git commit -m "feat: SourceManager wiring receivers to encoder to WebSocket"
```

---

### Task 7: SwiftUI Interface

**Files:**
- Create: `Sources/Indigo3/ContentView.swift`
- Modify: `Sources/Indigo3/Indigo3App.swift`

**Step 1: Create ContentView with source list and active streams**

```swift
// Sources/Indigo3/ContentView.swift
import SwiftUI

struct ContentView: View {
    @ObservedObject var sourceManager: SourceManager

    var body: some View {
        HSplitView {
            // Sources panel
            VStack(alignment: .leading) {
                Text("Sources")
                    .font(.headline)
                    .padding(.horizontal)

                List {
                    if !sourceManager.ndiSources.isEmpty {
                        Section("NDI") {
                            ForEach(sourceManager.ndiSources) { source in
                                HStack {
                                    Text(cleanNDIName(source.name))
                                    Spacer()
                                    Button("+") {
                                        sourceManager.addMapping(source: .ndi(source))
                                    }
                                }
                            }
                        }
                    }

                    if !sourceManager.syphonSources.isEmpty {
                        Section("Syphon") {
                            ForEach(sourceManager.syphonSources) { source in
                                HStack {
                                    Text("\(source.appName) - \(source.name)")
                                    Spacer()
                                    Button("+") {
                                        sourceManager.addMapping(source: .syphon(source))
                                    }
                                }
                            }
                        }
                    }

                    if sourceManager.ndiSources.isEmpty && sourceManager.syphonSources.isEmpty {
                        Text("Searching for sources...")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minWidth: 250)

            // Streams panel
            VStack(alignment: .leading) {
                HStack {
                    Text("Streams")
                        .font(.headline)
                    Spacer()
                    Text("ws://\(getLocalIP()):9000")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                List {
                    ForEach(sourceManager.mappings) { mapping in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Circle()
                                    .fill(mapping.isActive ? .green : .gray)
                                    .frame(width: 8, height: 8)
                                Text(mapping.source.name)
                                    .fontWeight(.medium)
                                Spacer()
                                Button("Remove") {
                                    sourceManager.removeMapping(mapping)
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                            }

                            HStack {
                                Text("ws://\(getLocalIP()):9000")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("ID: \(mapping.streamId)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            HStack {
                                Text("\(Int(mapping.fps)) fps")
                                    .font(.caption)
                                let clients = sourceManager.server.clientCounts[mapping.streamId] ?? 0
                                Text("\(clients) client\(clients == 1 ? "" : "s")")
                                    .font(.caption)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    if sourceManager.mappings.isEmpty {
                        Text("Add a source to start streaming")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minWidth: 300)
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}

private func cleanNDIName(_ name: String) -> String {
    // NDI names are "MACHINE (Source)" — extract just the source part
    if let range = name.range(of: "(") {
        let inside = name[range.upperBound...]
        if let end = inside.range(of: ")") {
            return String(inside[..<end.lowerBound])
        }
    }
    return name
}

func getLocalIP() -> String {
    var address = "localhost"
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return address }
    defer { freeifaddrs(ifaddr) }

    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        let interface = ptr.pointee
        let addrFamily = interface.ifa_addr.pointee.sa_family
        if addrFamily == UInt8(AF_INET) {
            let name = String(cString: interface.ifa_name)
            if name == "en0" {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                           &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                address = String(cString: hostname)
                break
            }
        }
    }
    return address
}
```

**Step 2: Update Indigo3App.swift**

```swift
// Sources/Indigo3/Indigo3App.swift
import SwiftUI

@main
struct Indigo3App: App {
    @StateObject private var sourceManager = SourceManager()

    var body: some Scene {
        WindowGroup {
            ContentView(sourceManager: sourceManager)
        }
    }

    init() {}

    class AppDelegate: NSObject, NSApplicationDelegate {
        var sourceManager: SourceManager?

        func applicationDidFinishLaunching(_ notification: Notification) {
            sourceManager?.startDiscovery()
            try? sourceManager?.server.start()
        }

        func applicationWillTerminate(_ notification: Notification) {
            sourceManager?.stopAll()
        }
    }
}
```

Note: The `@StateObject` init means we need to start discovery after the view appears. Update ContentView to add `.onAppear`:

Add to ContentView body, after `.frame(minWidth: 600, minHeight: 400)`:
```swift
.onAppear {
    sourceManager.startDiscovery()
    try? sourceManager.server.start()
}
```

**Step 3: Verify it builds**

Run: `cd /Users/jonas/Documents/GitHub/org/jonasjohansson/indigo3 && swift build`
Expected: BUILD SUCCEEDED

**Step 4: Run and verify window appears**

Run: `cd /Users/jonas/Documents/GitHub/org/jonasjohansson/indigo3 && swift run`
Expected: Window opens showing "Sources" and "Streams" panels. If NDI/Syphon sources are running, they should appear in the source list within 2 seconds.

**Step 5: Commit**

```bash
git add Sources/Indigo3/ContentView.swift Sources/Indigo3/Indigo3App.swift
git commit -m "feat: SwiftUI interface with source discovery and stream management"
```

---

### Task 8: Elverket Integration (WebCodecs receiver)

**Files:**
- Create: `/Users/jonas/Documents/GitHub/org/jonasjohansson/elverket/assets/js/3d/ndi-stream.js`
- Modify: `/Users/jonas/Documents/GitHub/org/jonasjohansson/elverket/assets/js/3d/texture.js`
- Modify: `/Users/jonas/Documents/GitHub/org/jonasjohansson/elverket/assets/js/ui/gui.js`

**Step 1: Create ndi-stream.js — WebCodecs receiver**

```javascript
// assets/js/3d/ndi-stream.js
import * as THREE from "three";

/**
 * Connects to an Indigo3 WebSocket stream and decodes H.264 NALUs
 * via WebCodecs, returning a Three.js CanvasTexture updated each frame.
 */
export class NDIStream {
  constructor(wsUrl, streamId) {
    this.wsUrl = wsUrl;
    this.streamId = streamId;
    this.decoder = null;
    this.ws = null;
    this.canvas = document.createElement("canvas");
    this.canvas.width = 1920;
    this.canvas.height = 1080;
    this.ctx = this.canvas.getContext("2d");
    this.texture = new THREE.CanvasTexture(this.canvas);
    this.texture.minFilter = THREE.LinearFilter;
    this.texture.magFilter = THREE.LinearFilter;
    this.texture.colorSpace = THREE.SRGBColorSpace;
    this.connected = false;
    this.configured = false;
  }

  connect() {
    this.ws = new WebSocket(this.wsUrl);
    this.ws.binaryType = "arraybuffer";

    this.ws.onopen = () => {
      // Send stream ID as first message
      this.ws.send(this.streamId);
      this.connected = true;
    };

    this.ws.onmessage = (e) => this._handleMessage(e.data);

    this.ws.onclose = () => {
      this.connected = false;
      // Auto-reconnect after 2s
      setTimeout(() => this.connect(), 2000);
    };

    this.ws.onerror = () => {
      this.ws.close();
    };
  }

  _initDecoder() {
    if (this.decoder) {
      this.decoder.close();
    }

    this.decoder = new VideoDecoder({
      output: (frame) => {
        // Draw VideoFrame to canvas, then update texture
        this.ctx.drawImage(frame, 0, 0, this.canvas.width, this.canvas.height);
        this.texture.needsUpdate = true;
        frame.close();
      },
      error: (e) => {
        console.error("VideoDecoder error:", e);
        this.configured = false;
      },
    });
  }

  _handleMessage(buffer) {
    const view = new DataView(buffer);
    const type = view.getUint8(0);
    const timestamp = Number(view.getBigUint64(1));
    const payload = new Uint8Array(buffer, 9);

    if (type === 0x00) {
      // SPS/PPS config — parse to get codec string and dimensions
      const config = this._parseConfig(payload);
      this._initDecoder();
      this.decoder.configure({
        codec: config.codec,
        codedWidth: config.width || 1920,
        codedHeight: config.height || 1080,
      });
      this.configured = true;
    } else if (this.configured && this.decoder.state === "configured") {
      this.decoder.decode(
        new EncodedVideoChunk({
          type: type === 0x01 ? "key" : "delta",
          timestamp: timestamp,
          data: payload,
        })
      );
    }
  }

  _parseConfig(data) {
    // Parse [spsLen(4)][sps][ppsLen(4)][pps]
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    const spsLen = view.getUint32(0);
    const sps = new Uint8Array(data.buffer, data.byteOffset + 4, spsLen);

    // Build avc1 codec string from SPS bytes
    // SPS[1]=profile_idc, SPS[2]=constraint_flags, SPS[3]=level_idc
    const profile = sps[1].toString(16).padStart(2, "0");
    const compat = sps[2].toString(16).padStart(2, "0");
    const level = sps[3].toString(16).padStart(2, "0");
    const codec = `avc1.${profile}${compat}${level}`;

    // Parse width/height from SPS would require full SPS parsing
    // Default to 1920x1080, canvas will scale
    return { codec, width: 1920, height: 1080 };
  }

  disconnect() {
    if (this.ws) {
      this.ws.onclose = null; // prevent auto-reconnect
      this.ws.close();
      this.ws = null;
    }
    if (this.decoder && this.decoder.state !== "closed") {
      this.decoder.close();
      this.decoder = null;
    }
    this.connected = false;
    this.configured = false;
  }

  dispose() {
    this.disconnect();
    this.texture.dispose();
  }
}
```

**Step 2: Add `applyNDIStreamToMesh` to texture.js**

Add to existing imports at top of `texture.js`:
```javascript
import { NDIStream } from "./ndi-stream.js";
```

Add new export function (before the `getTextureState` export):
```javascript
export function applyNDIStreamToMesh(mesh, wsUrl, streamId) {
  disposeTexture(mesh.name);

  const stream = new NDIStream(wsUrl, streamId);
  stream.connect();

  mesh.material = new THREE.MeshBasicMaterial({
    map: stream.texture,
    side: THREE.DoubleSide,
    toneMapped: false,
  });

  textureState.set(mesh.name, { texture: stream.texture, video: null, type: "ndistream", stream });
  return stream;
}
```

Update `disposeTexture` to handle NDIStream cleanup:
```javascript
function disposeTexture(meshName) {
  const state = textureState.get(meshName);
  if (!state) return;

  if (state.stream) {
    state.stream.dispose();
  }
  if (state.video) {
    state.video.pause();
    state.video.src = "";
    if (state.video.srcObject) {
      state.video.srcObject.getTracks().forEach((t) => t.stop());
    }
  }
  if (state.texture) state.texture.dispose();
  textureState.delete(meshName);
}
```

**Step 3: Add "NDI Stream" source option to gui.js**

Import the new function in gui.js:
```javascript
import {
  applyImageToMesh,
  applyVideoToMesh,
  applyWebcamToMesh,
  applyScreenCaptureToMesh,
  applyNDIStreamToMesh,
  clearTexture,
  setTextureTransform,
  getTextureState,
} from "../3d/texture.js";
```

In `setupSurfacesFolder`, update the per-surface source list options to add NDI Stream:
```javascript
options: [
  { text: "Baked Texture", value: "baked" },
  { text: "Upload Image", value: "image" },
  { text: "Upload Video", value: "video" },
  { text: "Webcam/OBS", value: "webcam" },
  { text: "NDI Stream", value: "ndistream" },
],
```

And add the handler in the source change callback:
```javascript
} else if (ev.value === "ndistream") {
  const url = prompt("Indigo3 WebSocket URL:", "ws://localhost:9000");
  const streamId = prompt("Stream ID:", "stream1");
  if (url && streamId) {
    applyNDIStreamToMesh(mesh, url, streamId);
  }
}
```

Also add "NDI Stream" to the "All Surfaces" list at the top:
```javascript
options: [
  { text: "—", value: "none" },
  { text: "Upload File", value: "upload" },
  { text: "Webcam/OBS", value: "webcam" },
  { text: "NDI Stream (All)", value: "ndistream" },
],
```

And its handler:
```javascript
} else if (ev.value === "ndistream") {
  const url = prompt("Indigo3 WebSocket URL:", "ws://localhost:9000");
  if (url) {
    let i = 1;
    for (const [, mesh] of meshRegistry) {
      applyNDIStreamToMesh(mesh, url, `stream${i}`);
      i++;
    }
  }
}
```

**Step 4: Verify elverket loads without errors**

Open `/Users/jonas/Documents/GitHub/org/jonasjohansson/elverket/index.html` in browser, open DevTools console.
Expected: No errors. "NDI Stream" option visible in Surface source dropdowns.

**Step 5: Commit (in elverket repo)**

```bash
cd /Users/jonas/Documents/GitHub/org/jonasjohansson/elverket
git add assets/js/3d/ndi-stream.js assets/js/3d/texture.js assets/js/ui/gui.js
git commit -m "feat: add NDI stream source via Indigo3 WebSocket + WebCodecs"
```

---

### Task 9: End-to-End Test

**Step 1: Start Resolume with NDI output**

Open Resolume Arena/Avenue with at least 1 NDI output enabled.

**Step 2: Build and run indigo3**

```bash
cd /Users/jonas/Documents/GitHub/org/jonasjohansson/indigo3
swift build && swift run
```

Expected: Window opens. NDI source(s) from Resolume appear in left panel within 2-4 seconds.

**Step 3: Add a stream mapping**

Click "+" next to a Resolume NDI source.
Expected: Stream appears in right panel with green dot, showing fps count increasing.

**Step 4: Connect elverket**

Open elverket in Chrome/Edge (WebCodecs required).
Select a surface → Source → "NDI Stream".
Enter `ws://localhost:9000` and `stream1`.

Expected: After ~0.5s, the Resolume video appears as a texture on the selected surface in Three.js.

**Step 5: Test with 5 streams**

Add 5 NDI sources in indigo3.
In elverket, use "All Surfaces → NDI Stream" with `ws://localhost:9000`.
Expected: All 5 surfaces show different Resolume outputs. FPS stays at ~30 per stream.

---

### Task 10: Polish and Stability

**Step 1: Handle encoder dimension mismatch**

If NDI sources are not 1920x1080, the encoder needs to match. Update `SourceManager.startMapping` to read first frame dimensions before creating the encoder, or make `StreamEncoder` recreate session on dimension change.

**Step 2: Add connection status to ContentView**

Show WebSocket server status (listening/error) and per-stream connection health.

**Step 3: Persist mappings**

Save/restore stream mappings to UserDefaults so they survive app restart.

**Step 4: Final commit**

```bash
cd /Users/jonas/Documents/GitHub/org/jonasjohansson/indigo3
git add -A
git commit -m "feat: polish, dimension handling, persistence"
```
