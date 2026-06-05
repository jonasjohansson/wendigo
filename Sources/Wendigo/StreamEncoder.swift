import Foundation
import VideoToolbox
import CoreMedia
import OSLog

private let logger = Logger(subsystem: "wendigo", category: "Encoder")

class StreamEncoder {
    private var session: VTCompressionSession?
    private var retainedSelf: Unmanaged<StreamEncoder>?  // prevents dangling pointer in VT callback
    private var vps: Data?  // HEVC only
    private var sps: Data?
    private var pps: Data?

    /// true = HEVC/H.265 (Safari only, decodes >4096 wide), false = H.264 (universal, ≤4096 wide).
    var useHEVC: Bool = false

    /// Called with encoded NALU data: (type, timestamp_us, data)
    /// type: 0x00 = parameter-set config, 0x01 = keyframe, 0x02 = delta
    var onEncodedFrame: ((UInt8, UInt64, Data) -> Void)?

    private(set) var currentWidth: Int32 = 0
    private(set) var currentHeight: Int32 = 0

    var currentResolution: String {
        currentWidth > 0 ? "\(currentWidth)x\(currentHeight)" : ""
    }
    /// Keyframe interval: 1 = all-intra (no stutter, huge bandwidth), higher = periodic keyframes.
    /// Default 60 (≈1 keyframe/sec at 60fps); all-intra at multi-stream 4K is the dominant cost.
    var keyframeInterval: Int = 60
    /// Bitrate in Mbps at 1080p — scales with resolution
    var bitrateMbps: Int = 30

    /// Set by stop(); prevents a late in-flight frame from resurrecting a new
    /// VTCompressionSession (and leaking it) after teardown.
    private var stopped = false

    /// Downscale source frames wider than this before encoding. 0 = source resolution.
    var maxOutputWidth: Int = 0
    private let scaler = FrameScaler()

    private var framesSinceLastInput: Int = 0
    private var forceNextKeyframe = false

    /// Ensure the compression session matches the given dimensions, recreating if needed.
    private func ensureSession(width: Int32, height: Int32) -> Bool {
        if width == currentWidth && height == currentHeight && session != nil {
            return true
        }

        // Tear down old session and release the retained self
        if let old = session {
            VTCompressionSessionCompleteFrames(old, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(old)
            session = nil
        }
        retainedSelf?.release()
        retainedSelf = nil

        currentWidth = width
        currentHeight = height
        vps = nil
        sps = nil
        pps = nil

        let callback: VTCompressionOutputCallback = { refcon, _, status, flags, sampleBuffer in
            guard status == noErr, let sampleBuffer = sampleBuffer, let refcon = refcon else { return }
            let encoder = Unmanaged<StreamEncoder>.fromOpaque(refcon).takeUnretainedValue()
            encoder.handleEncodedFrame(sampleBuffer)
        }

        // Retain self so the callback pointer stays valid for the session's lifetime
        let retained = Unmanaged.passRetained(self)
        retainedSelf = retained

        var status = VTCompressionSessionCreate(
            allocator: nil,
            width: width,
            height: height,
            codecType: useHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: retained.toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            logger.error("Failed to create H.264 session: \(status)")
            return false
        }
        let codecName = useHEVC ? "HEVC" : "H.264"
        logger.info("\(codecName, privacy: .public) encoder created: \(width)x\(height)")

        // Low-latency real-time H.264 encoding
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyframeInterval as CFNumber)
        // Bitrate need grows sub-linearly with resolution; HEVC needs ~0.6× of H.264
        // for equal quality. Linear scaling gave ~480 Mbps at 8K, which is wasteful.
        let pixels = Double(width) * Double(height)
        let resScale = pow(pixels / (1920.0 * 1080.0), 0.75)
        let codecFactor = useHEVC ? 0.6 : 1.0
        let bitrate = Int(Double(bitrateMbps) * 1_000_000 * resScale * codecFactor)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        // Cap peak bitrate to 2x average over 1 second
        let maxBytesPerSecond = (bitrate * 2) / 8
        let dataRateLimits: [Int] = [maxBytesPerSecond, 1]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: dataRateLimits as CFArray)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: useHEVC ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        // Help rate control plan ahead, and emit frames with no reordering delay (low latency).
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)

        status = VTCompressionSessionPrepareToEncodeFrames(session)
        return status == noErr
    }

    func encode(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        if stopped { return }
        // Optional downscale (Settings → Max width). 0 = encode at source resolution.
        let input = maxOutputWidth > 0 ? scaler.scaled(pixelBuffer, maxWidth: maxOutputWidth) : pixelBuffer
        let width = Int32(CVPixelBufferGetWidth(input))
        let height = Int32(CVPixelBufferGetHeight(input))
        guard ensureSession(width: width, height: height), let session = session else { return }

        var frameProps: CFDictionary? = nil
        if forceNextKeyframe {
            forceNextKeyframe = false
            frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: input,
            presentationTimeStamp: timestamp,
            duration: .invalid,
            frameProperties: frameProps,
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
            if CFDictionaryContainsKey(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()) {
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
        var dataPointer: UnsafeMutablePointer<Int8>?
        var length = 0
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let ptr = dataPointer else { return }
        let data = Data(bytes: ptr, count: length)
        let type: UInt8 = isKeyframe ? 0x01 : 0x02
        onEncodedFrame?(type, timestampUs, data)
    }

    private func extractParameterSets(_ formatDesc: CMFormatDescription) {
        if useHEVC {
            extractHEVCParameterSets(formatDesc)
        } else {
            extractH264ParameterSets(formatDesc)
        }
    }

    private func extractH264ParameterSets(_ formatDesc: CMFormatDescription) {
        // H.264 has 2 parameter sets: SPS (index 0), PPS (index 1)
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

        guard let spsPtr = spsPtr, let ppsPtr = ppsPtr else { return }
        let newSps = Data(bytes: spsPtr, count: spsSize)
        let newPps = Data(bytes: ppsPtr, count: ppsSize)

        // Only send if changed. Wire format: [spsLen(4)][sps][ppsLen(4)][pps]
        if newSps != sps || newPps != pps {
            sps = newSps
            pps = newPps
            onEncodedFrame?(0x00, 0, packConfig([newSps, newPps]))
        }
    }

    private func extractHEVCParameterSets(_ formatDesc: CMFormatDescription) {
        // HEVC has 3 parameter sets: VPS (0), SPS (1), PPS (2)
        var vpsSize = 0, vpsCount = 0, spsSize = 0, spsCount = 0, ppsSize = 0, ppsCount = 0
        var vpsPtr: UnsafePointer<UInt8>?
        var spsPtr: UnsafePointer<UInt8>?
        var ppsPtr: UnsafePointer<UInt8>?

        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDesc, parameterSetIndex: 0,
            parameterSetPointerOut: &vpsPtr, parameterSetSizeOut: &vpsSize,
            parameterSetCountOut: &vpsCount, nalUnitHeaderLengthOut: nil
        )
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDesc, parameterSetIndex: 1,
            parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil
        )
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDesc, parameterSetIndex: 2,
            parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: &ppsCount, nalUnitHeaderLengthOut: nil
        )

        guard let vpsPtr = vpsPtr, let spsPtr = spsPtr, let ppsPtr = ppsPtr else { return }
        let newVps = Data(bytes: vpsPtr, count: vpsSize)
        let newSps = Data(bytes: spsPtr, count: spsSize)
        let newPps = Data(bytes: ppsPtr, count: ppsSize)

        // VPS-first ordering is how the browser auto-detects HEVC.
        // Wire format: [vpsLen(4)][vps][spsLen(4)][sps][ppsLen(4)][pps]
        if newVps != vps || newSps != sps || newPps != pps {
            vps = newVps
            sps = newSps
            pps = newPps
            onEncodedFrame?(0x00, 0, packConfig([newVps, newSps, newPps]))
        }
    }

    /// Pack parameter sets, each as [len(4, big-endian)][nalu].
    private func packConfig(_ nalus: [Data]) -> Data {
        var data = Data()
        for nalu in nalus {
            var len = UInt32(nalu.count).bigEndian
            data.append(Data(bytes: &len, count: 4))
            data.append(nalu)
        }
        return data
    }

    var latestConfig: Data? {
        if useHEVC {
            guard let vps = vps, let sps = sps, let pps = pps else { return nil }
            return packConfig([vps, sps, pps])
        }
        guard let sps = sps, let pps = pps else { return nil }
        return packConfig([sps, pps])
    }

    func stop() {
        stopped = true
        if let session = session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        retainedSelf?.release()
        retainedSelf = nil
        // Reset dimensions so ensureSession recreates with new settings
        currentWidth = 0
        currentHeight = 0
    }

    deinit {
        // Don't call stop() in deinit — if we get here, retainedSelf was already released
        // (stop must be called explicitly before dropping the last external reference)
        if let session = session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }
}
