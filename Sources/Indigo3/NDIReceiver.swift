import Foundation
import CoreVideo
import os
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
    private let isRunning = OSAllocatedUnfairLock(initialState: false)
    private let receiveQueue = DispatchQueue(label: "indigo3.ndi.receive", qos: .userInteractive)
    private let loopExited = DispatchSemaphore(value: 0)

    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0

    var onPixelBuffer: ((CVPixelBuffer) -> Void)?

    func connect(to source: NDISourceInfo) {
        // Retain NSStrings so their utf8String pointers stay valid through NDI API calls
        let sourceName = source.name as NSString
        let recvName = "Indigo3" as NSString

        var ndiSource = NDIlib_source_t()
        ndiSource.p_ndi_name = sourceName.utf8String

        var settings = NDIlib_recv_create_v3_t()
        settings.source_to_connect_to = ndiSource
        settings.color_format = NDIlib_recv_color_format_BGRX_BGRA
        settings.bandwidth = NDIlib_recv_bandwidth_highest
        settings.allow_video_fields = true
        settings.p_ndi_recv_name = recvName.utf8String

        recvInstance = NDIlib_recv_create_v3(&settings)
        _ = (sourceName, recvName)  // prevent premature release
        guard recvInstance != nil else { return }

        isRunning.withLock { $0 = true }
        receiveQueue.async { [weak self] in
            self?.receiveLoop()
        }
    }

    private func receiveLoop() {
        defer { loopExited.signal() }
        guard let recv = recvInstance else { return }

        while isRunning.withLock({ $0 }) {
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

                    // Recreate pool if dimensions changed
                    if width != self.poolWidth || height != self.poolHeight {
                        let attrs: [String: Any] = [
                            kCVPixelBufferWidthKey as String: width,
                            kCVPixelBufferHeightKey as String: height,
                            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                        ]
                        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &self.pixelBufferPool)
                        self.poolWidth = width
                        self.poolHeight = height
                    }

                    // Get a reusable pixel buffer from the pool
                    var pixelBuffer: CVPixelBuffer?
                    if let pool = self.pixelBufferPool {
                        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
                    }
                    if let pb = pixelBuffer {
                        CVPixelBufferLockBaseAddress(pb, [])
                        let dest = CVPixelBufferGetBaseAddress(pb)!
                        let destStride = CVPixelBufferGetBytesPerRow(pb)
                        for row in 0..<height {
                            memcpy(dest.advanced(by: row * destStride),
                                   data.advanced(by: row * stride),
                                   min(stride, destStride))
                        }
                        CVPixelBufferUnlockBaseAddress(pb, [])
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
        let wasRunning = isRunning.withLock { val -> Bool in
            let was = val
            val = false
            return was
        }
        if wasRunning {
            // Wait for the receive loop to finish before destroying the instance
            loopExited.wait()
        }
        if let recv = recvInstance {
            NDIlib_recv_destroy(recv)
            recvInstance = nil
        }
    }

    deinit { disconnect() }
}
