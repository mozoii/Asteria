import Foundation
import Testing
@testable import GameStreamProtocol

@Suite("RTSP message encode/parse")
struct RTSPMessageTests {

    @Test func optionsSerializesExactly() {
        let req = RTSPRequest(method: "OPTIONS", uri: "rtsp://10.0.0.5:48010", cseq: 1)
        let expected = "OPTIONS rtsp://10.0.0.5:48010 RTSP/1.0\r\nCSeq: 1\r\n\r\n"
        #expect(String(decoding: req.serialized(), as: UTF8.self) == expected)
    }

    @Test func describeIncludesAcceptHeader() {
        let req = RTSPRequest(method: "DESCRIBE", uri: "rtsp://h:48010", cseq: 2,
                              headers: [("Accept", "application/sdp")])
        let text = String(decoding: req.serialized(), as: UTF8.self)
        #expect(text.hasPrefix("DESCRIBE rtsp://h:48010 RTSP/1.0\r\n"))
        #expect(text.contains("CSeq: 2\r\n"))
        #expect(text.contains("Accept: application/sdp\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }

    @Test func bodyAddsContentLengthAndAppends() {
        let body = Data("v=0\r\no=- 0 0 IN IP4 0.0.0.0\r\n".utf8)
        let req = RTSPRequest(method: "ANNOUNCE", uri: "rtsp://h:48010", cseq: 5,
                              headers: [("Content-Type", "application/sdp")], body: body)
        let data = req.serialized()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("Content-Type: application/sdp\r\n"))
        #expect(text.contains("Content-Length: \(body.count)\r\n"))
        let parts = text.components(separatedBy: "\r\n\r\n")
        #expect(parts.count == 2)
        #expect(parts[1] == String(decoding: body, as: UTF8.self))
    }

    @Test func parsesResponseStatusHeadersBody() throws {
        let raw = "RTSP/1.0 200 OK\r\nCSeq: 3\r\nSession: 0xABCD;timeout=60\r\nContent-Length: 5\r\n\r\nhello"
        let resp = try #require(RTSPResponse(parsing: Data(raw.utf8)))
        #expect(resp.statusCode == 200)
        #expect(resp.reason == "OK")
        #expect(resp.cseq == 3)
        #expect(resp.headerValue("session") == "0xABCD;timeout=60")
        #expect(String(decoding: resp.body, as: UTF8.self) == "hello")
    }

    @Test func parsesErrorStatus() throws {
        let resp = try #require(RTSPResponse(parsing: Data("RTSP/1.0 404 Not Found\r\nCSeq: 9\r\n\r\n".utf8)))
        #expect(resp.statusCode == 404)
        #expect(resp.reason == "Not Found")
        #expect(resp.body.isEmpty)
    }

    @Test func rejectsGarbage() {
        #expect(RTSPResponse(parsing: Data("not an rtsp response".utf8)) == nil)
    }
}
