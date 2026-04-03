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
