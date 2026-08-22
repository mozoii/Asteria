import CoreMedia

/// Builds `CMSampleBuffer`s from Annex B access units, tracking `CMVideoFormatDescription` from keyframe parameter sets.
public final class SampleBufferBuilder {
    public struct Output {
        public let sampleBuffer: CMSampleBuffer
        public let isKeyframe: Bool
        public let formatChanged: Bool   // format description was (re)built on this AU
    }

    public enum BuildResult: Equatable {
        case built(Output)
        case needsKeyframe   // no format description yet — waiting for parameter sets
        case empty           // no sample NALs to decode

        public static func == (lhs: BuildResult, rhs: BuildResult) -> Bool {
            switch (lhs, rhs) {
            case (.needsKeyframe, .needsKeyframe), (.empty, .empty): return true
            case (.built, .built): return true
            default: return false
            }
        }
    }

    private let codec: NALCodec
    public private(set) var formatDescription: CMVideoFormatDescription?

    public init(codec: NALCodec) {
        self.codec = codec
    }

    public func build(annexB: [UInt8], presentationTime: CMTime = .invalid) -> BuildResult {
        let accessUnit = AccessUnit.split(annexB, codec: codec)

        var formatChanged = false
        if accessUnit.isKeyframe, !accessUnit.parameterSets.isEmpty {
            if let newFormat = try? FormatDescriptionBuilder.make(
                codec: codec, parameterSets: accessUnit.parameterSets.map { Array($0) }) {
                if formatDescription == nil
                    || !CMFormatDescriptionEqual(newFormat, otherFormatDescription: formatDescription!) {
                    formatDescription = newFormat
                    formatChanged = true
                }
            }
        }

        guard let formatDescription else { return .needsKeyframe }

        let sampleData = AVCC.encode(accessUnit.sampleNALs)
        guard !sampleData.isEmpty,
              let sampleBuffer = Self.makeSampleBuffer(sampleData, format: formatDescription,
                                                       presentationTime: presentationTime) else {
            return .empty
        }
        return .built(Output(sampleBuffer: sampleBuffer,
                             isKeyframe: accessUnit.isKeyframe,
                             formatChanged: formatChanged))
    }

    /// Wrap length-prefixed sample data in `CMSampleBuffer` with format and optional presentation timestamp.
    static func makeSampleBuffer(_ data: [UInt8], format: CMVideoFormatDescription,
                                 presentationTime: CMTime = .invalid) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copyStatus = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = data.count
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: presentationTime,
                                        decodeTimeStamp: .invalid)
        // PTS invalid: pass entry count 0 to ignore timing.
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: presentationTime.isValid ? 1 : 0,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard sampleStatus == noErr else { return nil }
        return sampleBuffer
    }
}
