import Foundation
import CoreVideo
import Accelerate

/// Downscales BGRA CVPixelBuffers with vImage. Not thread-safe — use one per
/// encode queue (each StreamEncoder owns its own). Keeps a reusable output pool.
final class FrameScaler {
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    /// Returns a downscaled copy if `src` is wider than `maxWidth`, preserving
    /// aspect; otherwise returns `src` unchanged. Falls back to `src` on any error.
    func scaled(_ src: CVPixelBuffer, maxWidth: Int) -> CVPixelBuffer {
        let w = CVPixelBufferGetWidth(src)
        let h = CVPixelBufferGetHeight(src)
        guard maxWidth > 0, w > maxWidth, h > 0 else { return src }

        let targetW = maxWidth
        // Preserve aspect; keep even dimensions for the encoder's 4:2:0 chroma.
        let targetH = max(2, Int((Double(h) * Double(targetW) / Double(w)).rounded()) & ~1)

        if pool == nil || targetW != poolWidth || targetH != poolHeight {
            poolWidth = targetW
            poolHeight = targetH
            let attrs: [String: Any] = [
                kCVPixelBufferWidthKey as String: targetW,
                kCVPixelBufferHeightKey as String: targetH,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 3]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, attrs as CFDictionary, &newPool)
            pool = newPool
        }
        guard let pool = pool else { return src }

        var dstOpt: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dstOpt)
        guard let dst = dstOpt else { return src }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        guard let srcBase = CVPixelBufferGetBaseAddress(src),
              let dstBase = CVPixelBufferGetBaseAddress(dst) else { return src }

        var srcBuffer = vImage_Buffer(data: srcBase,
                                      height: vImagePixelCount(h),
                                      width: vImagePixelCount(w),
                                      rowBytes: CVPixelBufferGetBytesPerRow(src))
        var dstBuffer = vImage_Buffer(data: dstBase,
                                      height: vImagePixelCount(targetH),
                                      width: vImagePixelCount(targetW),
                                      rowBytes: CVPixelBufferGetBytesPerRow(dst))

        let err = vImageScale_ARGB8888(&srcBuffer, &dstBuffer, nil, vImage_Flags(kvImageNoFlags))
        return err == kvImageNoError ? dst : src
    }
}
