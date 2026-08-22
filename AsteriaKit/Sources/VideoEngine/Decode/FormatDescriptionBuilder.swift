import CoreMedia

public enum VideoFormatError: Error, Equatable {
    case parameterSetsMissing
    case creationFailed(OSStatus)
}

/// Build `CMVideoFormatDescription` from parameter sets with `nalUnitHeaderLength = 4` (matching AVCC).
public enum FormatDescriptionBuilder {
    public static func make(codec: NALCodec, parameterSets: [[UInt8]]) throws -> CMVideoFormatDescription {
        guard !parameterSets.isEmpty, parameterSets.allSatisfy({ !$0.isEmpty }) else {
            throw VideoFormatError.parameterSetsMissing
        }

        let sizes = parameterSets.map { $0.count }
        var format: CMVideoFormatDescription?
        let nalHeaderLength = Int32(AVCC.lengthPrefixSize)

        // Pin all parameter sets simultaneously (nested closures) so all base pointers stay valid for the CoreMedia call.
        let status = withPinnedPointers(parameterSets) { pointers in
            pointers.withUnsafeBufferPointer { pointerBuffer in
                sizes.withUnsafeBufferPointer { sizeBuffer in
                    switch codec {
                    case .h264:
                        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: parameterSets.count,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: nalHeaderLength,
                            formatDescriptionOut: &format)
                    case .hevc:
                        return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: parameterSets.count,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: nalHeaderLength,
                            extensions: nil,
                            formatDescriptionOut: &format)
                    }
                }
            }
        }

        guard status == noErr, let format else { throw VideoFormatError.creationFailed(status) }
        return format
    }

    /// Pin each set's storage, collect base pointers, and invoke body. Caller guarantees all sets are non-empty.
    private static func withPinnedPointers<R>(
        _ sets: [[UInt8]], _ body: ([UnsafePointer<UInt8>]) -> R
    ) -> R {
        var pointers: [UnsafePointer<UInt8>] = []
        pointers.reserveCapacity(sets.count)
        func recurse(_ index: Int) -> R {
            if index == sets.count { return body(pointers) }
            return sets[index].withUnsafeBufferPointer { buffer in
                pointers.append(buffer.baseAddress!)
                return recurse(index + 1)
            }
        }
        return recurse(0)
    }
}
