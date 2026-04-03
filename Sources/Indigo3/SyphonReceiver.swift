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

    // Reusable pixel buffer pool for GPU -> CVPixelBuffer conversion
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

        // Use a staging buffer + blit encoder for pipelined GPU-to-CPU copy
        let rowBytes = width * 4
        let bufferLength = rowBytes * height
        guard let stagingBuffer = device.makeBuffer(length: bufferLength, options: .storageModeShared),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            CVPixelBufferUnlockBaseAddress(pb, [])
            return
        }

        let sourceSize = MTLSize(width: width, height: height, depth: 1)
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(), sourceSize: sourceSize,
                  to: stagingBuffer, destinationOffset: 0,
                  destinationBytesPerRow: rowBytes, destinationBytesPerImage: bufferLength)
        blit.endEncoding()

        commandBuffer.addCompletedHandler { [weak self] _ in
            // Copy from staging buffer into CVPixelBuffer
            let src = stagingBuffer.contents()
            for row in 0..<height {
                let dstRow = dest.advanced(by: row * bytesPerRow)
                let srcRow = src.advanced(by: row * rowBytes)
                memcpy(dstRow, srcRow, rowBytes)
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            self?.onPixelBuffer?(pb)
        }

        commandBuffer.commit()
    }

    func disconnect() {
        client?.stop()
        client = nil
    }

    deinit { disconnect() }
}
