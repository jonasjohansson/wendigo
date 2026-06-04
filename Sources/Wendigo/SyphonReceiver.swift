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

    // Reusable GPU->CPU staging buffer, kept across frames to avoid per-frame allocation.
    private var reusableStagingBuffer: MTLBuffer?
    private var stagingLength: Int = 0

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
            if bytesPerRow == rowBytes {
                // One contiguous copy instead of one memcpy per row (2160 calls at 4K).
                memcpy(dest, src, bufferLength)
            } else {
                for row in 0..<height {
                    memcpy(dest.advanced(by: row * bytesPerRow), src.advanced(by: row * rowBytes), rowBytes)
                }
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
