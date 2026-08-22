import CoreMedia
import CoreVideo
import VideoToolbox

/// Synthetic fixture generator: encodes frames via VTCompressionSession; yields parameter sets + Annex B keyframe.
/// Safe reference holder: output handler runs synchronously during CompleteFrames.
private final class SampleBox: @unchecked Sendable {
    var sample: CMSampleBuffer?
}

enum SyntheticEncoder {
    struct Fixture {
        let formatDescription: CMVideoFormatDescription
        let parameterSets: [[UInt8]]   // raw NAL bytes, no start codes (SPS/PPS, or VPS/SPS/PPS)
        let annexB: [UInt8]            // full keyframe access unit: parameter sets + VCL, start-code framed
        let width: Int
        let height: Int
    }

    enum Failure: Error {
        case sessionCreate(OSStatus)
        case pixelBuffer(CVReturn)
        case encode(OSStatus)
        case noSampleBuffer
        case noFormatDescription
        case parameterSets(OSStatus)
        case noDataBuffer
    }

    private static let startCode: [UInt8] = [0, 0, 0, 1]

    static func encodeKeyframe(codec: CMVideoCodecType, width: Int = 128, height: Int = 64,
                               tenBit: Bool = false) throws -> Fixture {
        var session: VTCompressionSession?
        let createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height),
            codecType: codec,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session)
        guard createStatus == noErr, let session else { throw Failure.sessionCreate(createStatus) }
        defer { VTCompressionSessionInvalidate(session) }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        if tenBit {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                 value: kVTProfileLevel_HEVC_Main10_AutoLevel)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)

        let pixelBuffer = try makePixelBuffer(width: width, height: height, tenBit: tenBit)

        // The output handler runs synchronously before CompleteFrames returns, but the compiler can't
        // prove that — capture into a reference box to satisfy Sendable.
        let box = SampleBox()
        let frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        let encodeStatus = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(value: 0, timescale: 600),
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil) { status, _, sampleBuffer in
                if status == noErr, let sampleBuffer { box.sample = sampleBuffer }
            }
        guard encodeStatus == noErr else { throw Failure.encode(encodeStatus) }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

        guard let sample = box.sample else { throw Failure.noSampleBuffer }
        guard let format = CMSampleBufferGetFormatDescription(sample) else { throw Failure.noFormatDescription }

        let parameterSets = try extractParameterSets(format, codec: codec)
        let vclAnnexB = try avccToAnnexB(sample)
        var annexB = [UInt8]()
        for set in parameterSets { annexB += startCode + set }
        annexB += vclAnnexB

        return Fixture(formatDescription: format, parameterSets: parameterSets,
                       annexB: annexB, width: width, height: height)
    }

    private static func makePixelBuffer(width: Int, height: Int, tenBit: Bool) throws -> CVPixelBuffer {
        let format = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        var pixelBuffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attrs, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else { throw Failure.pixelBuffer(status) }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        if tenBit { fill10bit(pixelBuffer, width: width, height: height) }
        else { fill8bit(pixelBuffer, width: width, height: height) }
        return pixelBuffer
    }

    private static func fill8bit(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int) {
        // Luma ramp to produce non-trivial bitstream.
        if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let y = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                for col in 0..<width { y[row * stride + col] = UInt8((col * 255 / max(1, width)) & 0xFF) }
            }
        }
        // Neutral chroma (interleaved Cb=Cr=128).
        if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            let c = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<(height / 2) {
                for col in 0..<width { c[row * stride + col] = 128 }
            }
        }
    }

    /// 10-bit samples occupy the high 10 bits of each 16-bit word (x420 layout).
    private static func fill10bit(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int) {
        if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) / 2
            let y = base.assumingMemoryBound(to: UInt16.self)
            for row in 0..<height {
                for col in 0..<width { y[row * stride + col] = UInt16((col * 1023 / max(1, width)) & 0x3FF) << 6 }
            }
        }
        if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) / 2
            let c = base.assumingMemoryBound(to: UInt16.self)
            for row in 0..<(height / 2) {
                for col in 0..<width { c[row * stride + col] = UInt16(512) << 6 }
            }
        }
    }

    private static func extractParameterSets(_ format: CMVideoFormatDescription,
                                             codec: CMVideoCodecType) throws -> [[UInt8]] {
        let isHEVC = codec == kCMVideoCodecType_HEVC
        var count = 0
        let countStatus = isHEVC
            ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        guard countStatus == noErr else { throw Failure.parameterSets(countStatus) }

        var sets: [[UInt8]] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = isHEVC
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer else { throw Failure.parameterSets(status) }
            sets.append(Array(UnsafeBufferPointer(start: pointer, count: size)))
        }
        return sets
    }

    private static func avccToAnnexB(_ sample: CMSampleBuffer) throws -> [UInt8] {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { throw Failure.noDataBuffer }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                                 totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard status == noErr, let dataPointer else { throw Failure.noDataBuffer }

        let bytes = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: UInt8.self)
        var out = [UInt8]()
        var i = 0
        while i + 4 <= totalLength {
            let nalLength = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            i += 4
            guard nalLength > 0, i + nalLength <= totalLength else { break }
            out += startCode
            out += Array(UnsafeBufferPointer(start: bytes + i, count: nalLength))
            i += nalLength
        }
        return out
    }
}
