import Foundation
import AppKit
import Metal
import CoreVideo
import OSLog
import CSyphon

private let logger = Logger(subsystem: "wendigo", category: "Syphon")

struct SyphonSourceInfo: Identifiable, Hashable, Codable {
    let id: UUID
    let name: String
    let appName: String

    init(name: String, appName: String) {
        self.id = UUID()
        self.name = name
        self.appName = appName
    }
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

    // Reusable pixel buffer pool for GPU -> CVPixelBuffer conversion
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0

    // Reusable GPU->CPU staging buffer, kept across frames (CPU fallback path only).
    private var reusableStagingBuffer: MTLBuffer?
    private var stagingLength: Int = 0

    // GPU zero-copy path: render Syphon's texture straight into the pixel buffer's IOSurface.
    private var textureCache: CVMetalTextureCache?
    private var flipPipeline: MTLRenderPipelineState?

    var onPixelBuffer: ((CVPixelBuffer) -> Void)?

    init?(device: MTLDevice? = nil) {
        guard let dev = device ?? MTLCreateSystemDefaultDevice() else { return nil }
        guard let queue = dev.makeCommandQueue() else { return nil }
        self.device = dev
        self.commandQueue = queue
        CVMetalTextureCacheCreate(nil, nil, dev, nil, &textureCache)
        self.flipPipeline = Self.makeFlipPipeline(device: dev)
    }

    /// Pipeline that draws a full-screen triangle, sampling the source texture with a
    /// vertical flip (Syphon's GL bottom-left origin -> CoreVideo's top-left).
    private static func makeFlipPipeline(device: MTLDevice) -> MTLRenderPipelineState? {
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 pos [[position]]; float2 uv; };
        vertex VOut v_flip(uint vid [[vertex_id]]) {
            float2 p = float2(float((vid << 1) & 2), float(vid & 2));
            VOut o;
            o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
            o.uv = p;  // uv.y = p.y => vertical flip
            return o;
        }
        fragment float4 f_flip(VOut v [[stage_in]], texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            return tex.sample(s, v.uv);
        }
        """
        guard let lib = try? device.makeLibrary(source: src, options: nil),
              let vfn = lib.makeFunction(name: "v_flip"),
              let ffn = lib.makeFunction(name: "f_flip") else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: desc)
    }

    /// Render `texture` (flipped) directly into the IOSurface-backed pixel buffer.
    /// Returns false (leaving `pb` untouched) when the GPU path isn't available.
    private func gpuConvert(_ texture: any MTLTexture, into pb: CVPixelBuffer, width: Int, height: Int) -> Bool {
        guard let cache = textureCache, let pipeline = flipPipeline else { return false }
        var cvTexOut: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pb, nil, .bgra8Unorm, width, height, 0, &cvTexOut)
        guard status == kCVReturnSuccess, let cvTex = cvTexOut,
              let destTex = CVMetalTextureGetTexture(cvTex),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = destTex
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return false }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(texture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        commandBuffer.addCompletedHandler { [weak self] _ in
            _ = cvTex  // hold the CVMetalTexture alive until the GPU finishes
            self?.onPixelBuffer?(pb)
        }
        commandBuffer.commit()
        return true
    }

    func connect(to source: SyphonSourceInfo) {
        guard let servers = SyphonServerDirectory.shared().servers as? [[String: Any]] else { return }

        let matching = servers.first { server in
            let name = server[SyphonServerDescriptionNameKey as String] as? String ?? ""
            let app = server[SyphonServerDescriptionAppNameKey as String] as? String ?? ""
            return name == source.name && app == source.appName
        }

        guard let serverDesc = matching else {
            logger.warning("Syphon server not found: \(source.appName) - \(source.name)")
            return
        }
        logger.info("Connecting to Syphon: \(source.appName) - \(source.name)")

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
            // Release old pool before creating new one to avoid memory leak
            pixelBufferPool = nil
            let attrs: [String: Any] = [
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
            let poolAttrs: [String: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey as String: 6
            ]
            CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, attrs as CFDictionary, &pixelBufferPool)
            poolWidth = width
            poolHeight = height
            logger.info("Syphon pool recreated: \(width)x\(height)")
        }

        guard let pool = pixelBufferPool else { return }

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pb = pixelBuffer else { return }

        // Fast path: GPU render straight into the IOSurface — no CPU copy, no blocking wait.
        if gpuConvert(texture, into: pb, width: width, height: height) { return }

        // Fallback: GPU blit to a staging buffer, then CPU flip-copy.
        let rowBytes = width * 4
        let bufferLength = rowBytes * height

        // Reuse one staging buffer across frames. Allocating a fresh 33MB Metal
        // buffer every frame (per the old code) was ~5GB/s of allocation churn
        // with five 4K sources.
        if reusableStagingBuffer == nil || stagingLength != bufferLength {
            reusableStagingBuffer = device.makeBuffer(length: bufferLength, options: .storageModeShared)
            stagingLength = bufferLength
        }
        guard let staging = reusableStagingBuffer,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return }

        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: staging, destinationOffset: 0,
                  destinationBytesPerRow: rowBytes, destinationBytesPerImage: bufferLength)
        blit.endEncoding()
        // Synchronous: the single reused staging buffer must not be overwritten by
        // the next frame mid-copy. The blit is just a memcpy on the GPU (sub-ms).
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        CVPixelBufferLockBaseAddress(pb, [])
        if let dest = CVPixelBufferGetBaseAddress(pb) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
            let src = staging.contents()
            // Syphon uses a bottom-left (GL) origin; flip vertically into the
            // top-left CVPixelBuffer so the encoded frame isn't upside down.
            // Same bytes moved as a straight copy, just reversed row order.
            for row in 0..<height {
                let srcRow = src.advanced(by: row * rowBytes)
                let dstRow = dest.advanced(by: (height - 1 - row) * bytesPerRow)
                memcpy(dstRow, srcRow, rowBytes)
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        onPixelBuffer?(pb)
    }

    func disconnect() {
        client?.stop()
        client = nil
    }

    deinit { disconnect() }
}
