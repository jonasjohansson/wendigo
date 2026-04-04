import Foundation
import VideoToolbox
import CoreMedia

class StreamEncoder {
    private var session: VTCompressionSession?
    private var retainedSelf: Unmanaged<StreamEncoder>?  // prevents dangling pointer in VT callback
    private var vps: Data?
    private var sps: Data?
    private var pps: Data?

    /// Called with encoded NALU data: (type, timestamp_us, data)
    /// type: 0x00 = VPS/SPS/PPS config, 0x01 = keyframe, 0x02 = delta
    var onEncodedFrame: ((UInt8, UInt64, Data) -> Void)?

    private var currentWidth: Int32 = 0
    private var currentHeight: Int32 = 0

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
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: retained.toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else { return false }

        // Low-latency real-time HEVC encoding
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFNumber)
        // Scale bitrate with pixel count (10 Mbps baseline at 1080p — HEVC is ~40% more efficient)
        let pixels = Double(width) * Double(height)
        let bitrate = Int(10_000_000 * (pixels / (1920.0 * 1080.0)))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_HEVC_Main_AutoLevel)

        status = VTCompressionSessionPrepareToEncodeFrames(session)
        return status == noErr
    }

    func encode(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
        guard ensureSession(width: width, height: height), let session = session else { return }
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
            if CFDictionaryContainsKey(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()) {
                isKeyframe = false
            }
        }

        // Extract VPS/SPS/PPS from keyframes
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
        // HEVC has 3 parameter sets: VPS (index 0), SPS (index 1), PPS (index 2)
        var vpsSize = 0, vpsCount = 0
        var spsSize = 0, spsCount = 0
        var ppsSize = 0, ppsCount = 0
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

        if let vpsPtr = vpsPtr, let spsPtr = spsPtr, let ppsPtr = ppsPtr {
            let newVps = Data(bytes: vpsPtr, count: vpsSize)
            let newSps = Data(bytes: spsPtr, count: spsSize)
            let newPps = Data(bytes: ppsPtr, count: ppsSize)

            // Only send if changed
            if newVps != vps || newSps != sps || newPps != pps {
                vps = newVps
                sps = newSps
                pps = newPps
                // Pack VPS + SPS + PPS: [vpsLen(4)] [vps] [spsLen(4)] [sps] [ppsLen(4)] [pps]
                var configData = Data()
                var vLen = UInt32(vpsSize).bigEndian
                var sLen = UInt32(spsSize).bigEndian
                var pLen = UInt32(ppsSize).bigEndian
                configData.append(Data(bytes: &vLen, count: 4))
                configData.append(newVps)
                configData.append(Data(bytes: &sLen, count: 4))
                configData.append(newSps)
                configData.append(Data(bytes: &pLen, count: 4))
                configData.append(newPps)
                onEncodedFrame?(0x00, 0, configData)
            }
        }
    }

    var latestConfig: Data? {
        guard let vps = vps, let sps = sps, let pps = pps else { return nil }
        var configData = Data()
        var vLen = UInt32(vps.count).bigEndian
        var sLen = UInt32(sps.count).bigEndian
        var pLen = UInt32(pps.count).bigEndian
        configData.append(Data(bytes: &vLen, count: 4))
        configData.append(vps)
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
        retainedSelf?.release()
        retainedSelf = nil
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
