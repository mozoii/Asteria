import Foundation
import Testing
@testable import GameStreamProtocol

@Suite("RTSP response framing")
struct RTSPFramerTests {

    @Test func waitsForFullBodyPerContentLength() {
        var framer = RTSPResponseFramer()
        #expect(framer.append(Data("RTSP/1.0 200 OK\r\nCSeq: 2\r\nContent-Length: 5\r\n\r\nhel".utf8)) == nil)
        let resp = framer.append(Data("lo".utf8))
        #expect(resp != nil)
        #expect(String(decoding: resp!.body, as: UTF8.self) == "hello")
    }

    @Test func closeDelimitedBodyFinalizesAtEOF() {
        var framer = RTSPResponseFramer()
        #expect(framer.append(Data("RTSP/1.0 200 OK\r\nCSeq: 2\r\n\r\nv=0\r\na=x-nv\r\n".utf8)) == nil)
        let resp = framer.finish()
        #expect(resp?.statusCode == 200)
        #expect(String(decoding: resp!.body, as: UTF8.self) == "v=0\r\na=x-nv\r\n")
    }

    @Test func headerOnlyReplyFinalizesAtEOF() {
        var framer = RTSPResponseFramer()
        #expect(framer.append(Data("RTSP/1.0 200 OK\r\nCSeq: 3\r\nSession: ABC\r\n\r\n".utf8)) == nil)
        let resp = framer.finish()
        #expect(resp?.statusCode == 200)
        #expect(resp?.headerValue("session") == "ABC")
        #expect(resp!.body.isEmpty)
    }

    @Test func terminalChunkFinalizesCloseDelimitedReply() throws {
        var framer = RTSPResponseFramer()
        let resp = try framer.ingest(
            Data("RTSP/1.0 200 OK\r\nCSeq: 4\r\n\r\nv=0\r\n".utf8),
            endOfStream: true
        )
        #expect(resp?.statusCode == 200)
        #expect(String(decoding: resp!.body, as: UTF8.self) == "v=0\r\n")
    }
}
