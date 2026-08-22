import Foundation
import Testing
@testable import GameStreamProtocol

@Suite("SDP generate/parse")
struct SDPTests {

    private func config() -> StreamConfiguration {
        StreamConfiguration(
            width: 2560, height: 1440, fps: 120,
            bitrateKbps: 40_000, packetSize: 1392,
            videoFormat: .hevc, audio: .stereo, hdr: false,
            remoteInputAesKey: Array(repeating: 0, count: 16), remoteInputAesKeyId: 0
        )
    }

    @Test func announceOpensWithSessionAndClosesWithMediaTail() {
        let sdp = AnnounceSDPBuilder.announce(for: config(), host: "10.0.0.5", videoServerPort: 47998)
        #expect(sdp.hasPrefix("v=0\r\n"))
        #expect(sdp.contains("o=- 0 14 IN IPv4 10.0.0.5\r\n"))
        #expect(sdp.contains("s=Asteria Streaming Client\r\n"))
        #expect(sdp.contains("t=0 0\r\n"))
        #expect(sdp.hasSuffix("m=video 47998\r\n"))
    }

    @Test func announceCarriesCoreStreamConfiguration() {
        let sdp = AnnounceSDPBuilder.announce(for: config(), host: "10.0.0.5", videoServerPort: 47998)
        #expect(sdp.contains("a=x-nv-video[0].clientViewportWd:2560\r\n"))
        #expect(sdp.contains("a=x-nv-video[0].clientViewportHt:1440\r\n"))
        #expect(sdp.contains("a=x-nv-video[0].maxFPS:120\r\n"))
        #expect(sdp.contains("a=x-nv-video[0].clientRefreshRateX100:12000\r\n"))
        #expect(sdp.contains("a=x-nv-video[0].packetSize:1392\r\n"))
        #expect(sdp.contains("a=x-nv-video[0].videoEncoderSlicesPerFrame:1\r\n"))
        #expect(sdp.contains("a=x-nv-video[0].maxNumReferenceFrames:1\r\n"))
        // 40,000 kbps × 80% FEC headroom = 32,000; configured rate reported unadjusted.
        #expect(sdp.contains("a=x-nv-vqos[0].bw.maximumBitrateKbps:32000\r\n"))
        #expect(sdp.contains("a=x-ml-video.configuredBitrateKbps:40000\r\n"))
        #expect(sdp.contains("a=x-nv-audio.surround.numChannels:2\r\n"))
        #expect(sdp.contains("a=x-nv-audio.surround.channelMask:3\r\n"))
    }

    @Test func announceCarriesNegotiatedBehaviorOptIns() {
        let sdp = AnnounceSDPBuilder.announce(for: config(), host: "10.0.0.5")
        #expect(sdp.contains("a=x-ss-general.encryptionEnabled:1\r\n"))
        #expect(sdp.contains("a=x-ml-general.featureFlags:3\r\n"))
        #expect(sdp.contains("a=x-nv-general.useReliableUdp:13\r\n"))
        #expect(sdp.contains("a=x-nv-vqos[0].fec.minRequiredFecPackets:2\r\n"))
        #expect(sdp.contains("a=x-nv-audio.surround.AudioQuality:0\r\n"))
    }

    @Test func announceOmitsAttributesTheHostDefaultsOrIgnores() {
        let sdp = AnnounceSDPBuilder.announce(for: config(), host: "10.0.0.5")
        // Host-defaulted to our values: featureFlags, encoderCscMode, packetDuration,
        // qosTrafficType, aqosTrafficType.
        for ignored in ["x-nv-general.featureFlags", "x-nv-video[0].encoderCscMode",
                        "x-nv-aqos.packetDuration", "x-nv-vqos[0].qosTrafficType",
                        "x-nv-aqos.qosTrafficType",
                        // Never consumed by Sunshine/Apollo ANNOUNCE handling.
                        "x-nv-video[0].rateControlMode", "x-nv-video[0].timeoutLengthMs",
                        "x-nv-video[0].framesWithInvalidRefThreshold",
                        "x-nv-video[0].initialBitrateKbps", "x-nv-video[0].initialPeakBitrateKbps",
                        "x-nv-vqos[0].bw.minimumBitrateKbps", "x-nv-vqos[0].fec.enable",
                        "x-nv-vqos[0].bllFec.enable", "x-nv-vqos[0].drc.enable",
                        "x-nv-vqos[0].videoQualityScoreUpdateTime",
                        "x-nv-general.enableRecoveryMode", "x-nv-clientSupportHevc",
                        "x-nv-audio.surround.enable"] {
            #expect(!sdp.contains(ignored), "\(ignored) should not be sent")
        }
        // Defaulted attribute values must not appear under their names either.
        #expect(!sdp.contains("dynamicRangeMode"))
        #expect(!sdp.contains("chromaSamplingType"))
    }

    @Test func announceOrdersAttributesByNegotiationGroups() {
        let sdp = AnnounceSDPBuilder.announce(for: config(), host: "10.0.0.5", videoServerPort: 47998)
        // The builder groups attributes by negotiation concern; each group must appear in full
        // before the next, and attributes within a group keep their fixed order.
        let groups: [(name: String, lines: [String])] = [
            ("session", ["x-ss-general.encryptionEnabled:1", "x-ml-general.featureFlags:3",
                         "x-nv-general.useReliableUdp:13"]),
            ("video", ["x-nv-video[0].clientViewportWd:2560", "x-nv-video[0].clientViewportHt:1440",
                       "x-nv-video[0].maxFPS:120", "x-nv-video[0].clientRefreshRateX100:12000",
                       "x-nv-video[0].packetSize:1392", "x-nv-video[0].videoEncoderSlicesPerFrame:1",
                       "x-nv-video[0].maxNumReferenceFrames:1"]),
            ("codec", ["x-nv-vqos[0].bitStreamFormat:1"]),
            ("qos", ["x-nv-vqos[0].bw.maximumBitrateKbps:32000",
                     "x-nv-vqos[0].fec.minRequiredFecPackets:2",
                     "x-ml-video.configuredBitrateKbps:40000"]),
            ("audio", ["x-nv-audio.surround.numChannels:2", "x-nv-audio.surround.channelMask:3",
                       "x-nv-audio.surround.AudioQuality:0"]),
        ]
        var searchStart = sdp.startIndex
        for group in groups {
            for line in group.lines {
                let needle = "a=\(line)\r\n"
                guard let range = sdp.range(of: needle, range: searchStart..<sdp.endIndex) else {
                    Issue.record("Missing \(group.name) attribute: \(line)")
                    continue
                }
                searchStart = range.upperBound
            }
        }
    }

    @Test func announceBranchMatrix() {
        func sdp(videoFormat: VideoFormat, audio: AudioConfiguration, hdr: Bool) -> String {
            var c = config()
            c.videoFormat = videoFormat
            c.audio = audio
            c.hdr = hdr
            return AnnounceSDPBuilder.announce(for: c, host: "10.0.0.5")
        }

        // H.264 branch: no bitStreamFormat (host defaults to H.264).
        let avc = sdp(videoFormat: .h264, audio: .stereo, hdr: false)
        #expect(!avc.contains("bitStreamFormat"))

        // HEVC branch.
        let hevc = sdp(videoFormat: .hevc, audio: .stereo, hdr: false)
        #expect(hevc.contains("a=x-nv-vqos[0].bitStreamFormat:1\r\n"))

        // AV1 branch.
        let av1 = sdp(videoFormat: .av1Main8, audio: .stereo, hdr: false)
        #expect(av1.contains("a=x-nv-vqos[0].bitStreamFormat:2\r\n"))

        // 4:4:4 sampling advertised only for 4:4:4 formats.
        let h264_444 = sdp(videoFormat: .h264High8_444, audio: .stereo, hdr: false)
        #expect(h264_444.contains("a=x-ss-video[0].chromaSamplingType:1\r\n"))
        #expect(!hevc.contains("chromaSamplingType"))

        // HDR mode advertised only when enabled.
        let hdr = sdp(videoFormat: .hevcMain10, audio: .stereo, hdr: true)
        #expect(hdr.contains("a=x-nv-video[0].dynamicRangeMode:1\r\n"))
        #expect(!hevc.contains("dynamicRangeMode"))

        // Surround layout.
        let surround = sdp(videoFormat: .hevc, audio: .surround51, hdr: false)
        #expect(surround.contains("a=x-nv-audio.surround.numChannels:6\r\n"))
        #expect(surround.contains("a=x-nv-audio.surround.channelMask:63\r\n"))

        // Rate ceiling clamps at 100,000 kbps.
        var capped = config()
        capped.bitrateKbps = 250_000
        let cappedSDP = AnnounceSDPBuilder.announce(for: capped, host: "10.0.0.5")
        #expect(cappedSDP.contains("a=x-nv-vqos[0].bw.maximumBitrateKbps:100000\r\n"))
    }

    @Test func parsesVideoServerPortFromTransport() {
        #expect(RTSPHandshake.serverPort(from: "server_port=47998") == 47998)
        #expect(RTSPHandshake.serverPort(from: "unicast;server_port=48000;foo") == 48000)
        #expect(RTSPHandshake.serverPort(from: "no port here") == nil)
    }

    @Test func parsesMediaPortsAndAttributes() throws {
        let raw = [
            "v=0",
            "o=- 0 0 IN IP4 10.0.0.5",
            "s=Sunshine Gamestream",
            "t=0 0",
            "m=video 47998 RTP/AVP 97",
            "a=rtpmap:97 H265/90000",
            "a=x-nv-video[0].clientViewportWd:1920",
            "m=audio 48000 RTP/AVP 98",
        ].joined(separator: "\r\n") + "\r\n"
        let sdp = try #require(SessionDescription(parsing: raw))
        let media = sdp.mediaDescriptions
        #expect(media.count == 2)
        #expect(media[0].type == "video")
        #expect(media[0].port == 47998)
        #expect(media[1].type == "audio")
        #expect(media[1].port == 48000)
        #expect(sdp.attribute("x-nv-video[0].clientViewportWd") == "1920")
        #expect(sdp.attribute("rtpmap") == "97 H265/90000")
    }

    @Test func rejectsNonSdp() {
        #expect(SessionDescription(parsing: "garbage\r\n") == nil)
    }

    @Test func detectsReferenceFrameInvalidationAttribute() throws {
        let withRFI = [
            "v=0", "o=- 0 0 IN IP4 10.0.0.5", "t=0 0", "m=video 47998 RTP/AVP 97",
            "a=x-nv-video[0].refPicInvalidation:1", "a=x-nv-video[0].clientViewportWd:1920",
        ].joined(separator: "\r\n") + "\r\n"
        #expect(try #require(SessionDescription(parsing: withRFI)).advertisesReferenceFrameInvalidation)
    }

    @Test func detectsValuelessReferenceFrameInvalidationAttribute() throws {
        let raw = ["v=0", "t=0 0", "a=x-nv-video[0].refPicInvalidation"].joined(separator: "\r\n") + "\r\n"
        #expect(try #require(SessionDescription(parsing: raw)).advertisesReferenceFrameInvalidation)
    }

    @Test func noReferenceFrameInvalidationWhenAbsent() throws {
        let raw = ["v=0", "t=0 0", "a=x-nv-video[0].clientViewportWd:1920"].joined(separator: "\r\n") + "\r\n"
        #expect(!(try #require(SessionDescription(parsing: raw)).advertisesReferenceFrameInvalidation))
    }
}
