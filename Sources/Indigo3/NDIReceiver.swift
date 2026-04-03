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
