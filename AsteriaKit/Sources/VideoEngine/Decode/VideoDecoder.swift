import Foundation
import CoreMedia
import CoreVideo
import QuartzCore
import VideoToolbox

/// Result of submitting an access unit; signals whether to request a keyframe from the host.
public enum SubmitStatus: Sendable, Equatable {
    case ok          // decode dispatched
    case needsIdr    // can't decode yet, session failed, or the decode call errored — request an IDR
    case dropped     // malformed access unit, nothing to decode
}

/// Hardware video decode (actor): owns `VTDecompressionSession`, (re)builds from keyframe param sets, feeds decoded frames to `LatestFrameHolder` off-actor.
public actor VideoDecoder {
    private let builder: SampleBufferBuilder
    private let holder: LatestFrameHolder
    private let outputPixelFormat: OSType
    private var session: VTDecompressionSession?

    /// Decoded-buffer pixel format for the negotiated bit depth; 10-bit keeps the full samples instead of truncating to 8.
    public static func outputPixelFormat(tenBit: Bool) -> OSType {
        tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
               : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    public init(codec: NALCodec,
                holder: LatestFrameHolder,
                outputPixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        self.builder = SampleBufferBuilder(codec: codec)
        self.holder = holder
        self.outputPixelFormat = outputPixelFormat
    }

    /// Submit Annex B access unit; keyframes (re)create the session. Returns `.needsIdr` until first keyframe.
    public func submit(annexB: [UInt8], frameIndex: UInt32) -> SubmitStatus {
        let built: SampleBufferBuilder.Output
        switch builder.build(annexB: annexB) {
        case .needsKeyframe: return .needsIdr
        case .empty: return .dropped
        case .built(let output): built = output
        }

        if session == nil || built.formatChanged {
            guard let format = builder.formatDescription else { return .needsIdr }
            recreateSession(formatDescription: format)
        }
        guard let session else { return .needsIdr }

        // Output handler runs off-actor (Sendable holder + frame index).
        let holder = self.holder
        let submittedAt = CACurrentMediaTime()
        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: built.sampleBuffer, flags: flags, infoFlagsOut: nil
        ) { status, _, imageBuffer, _, _ in
            if status == noErr, let imageBuffer {
                holder.store(imageBuffer, frameIndex: frameIndex,
                             decodeSeconds: CACurrentMediaTime() - submittedAt)
            }
        }
        // Any sync decode error also requests a full IDR: transient VideoToolbox failures recover by re-keying.
        return status == noErr ? .ok : .needsIdr
    }

    private func recreateSession(formatDescription: CMVideoFormatDescription) {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }

        let imageBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: outputPixelFormat,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        let decoderSpecification: [CFString: Any] = [
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true,
        ]

        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpecification as CFDictionary,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession)

        if status == noErr, let newSession {
            VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            self.session = newSession
        }
    }

    /// Block until in-flight frames deliver to holder (test aid).
    public func waitForFrames() {
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
    }

    public func stop() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
    }
}
