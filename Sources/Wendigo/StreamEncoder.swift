import Foundation
import VideoToolbox
import CoreMedia
import OSLog

private let logger = Logger(subsystem: "wendigo", category: "Encoder")

class StreamEncoder {
    private var session: VTCompressionSession?
    private var retainedSelf: Unmanaged<StreamEncoder>?  // prevents dangling pointer in VT callback
    private var sps: Data?
    private var pps: Data?

    /// Called with encoded NALU data: (type, timestamp_us, data)
    /// type: 0x00 = SPS/PPS config, 0x01 = keyframe, 0x02 = delta
    var onEncodedFrame: ((UInt8, UInt64, Data) -> Void)?

    private(set) var currentWidth: Int32 = 0
    private(set) var currentHeight: Int32 = 0

    var currentResolution: String {
        currentWidth > 0 ? "\(currentWidth)x\(currentHeight)" : ""
    }
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
            codecType: kCMVideoCodecType_H264,
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
        logger.info("H.264 encoder created: \(width)x\(height)")

        // Low-latency real-time H.264 encoding
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 300 as CFNumber)
        // Scale bitrate with pixel count (5 Mbps baseline at 1080p — keeps GPU load manageable with multiple streams)
        let pixels = Double(width) * Double(height)
        let bitrate = Int(5_000_000 * (pixels / (1920.0 * 1080.0)))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        // Cap peak bitrate to 2x average over 1 second — prevents keyframe spikes
        let maxBytesPerSecond = (bitrate * 2) / 8
        let dataRateLimits: [Int] = [maxBytesPerSecond, 1]  // [bytes, seconds]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: dataRateLimits as CFArray)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_High_AutoLevel)

        status = VTCompressionSessionPrepareToEncodeFrames(session)
        return status == noErr
    }

    func encode(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
        guard ensureSession(width: width, height: height), let session = session else { return }

        var frameProps: CFDictionary? = nil
        if forceNextKeyframe {
            forceNextKeyframe = false
            frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
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

        if let spsPtr = spsPtr, let ppsPtr = ppsPtr {
            let newSps = Data(bytes: spsPtr, count: spsSize)
            let newPps = Data(bytes: ppsPtr, count: ppsSize)

            // Only send if changed
            if newSps != sps || newPps != pps {
                sps = newSps
                pps = newPps
                // Pack SPS + PPS: [spsLen(4)] [sps] [ppsLen(4)] [pps]
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
