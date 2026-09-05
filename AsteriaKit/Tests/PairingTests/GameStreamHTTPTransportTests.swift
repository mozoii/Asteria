import Foundation
import Testing
@testable import Pairing

@Suite("GameStream HTTP transport")
struct GameStreamHTTPTransportTests {
    @Test("server certificate pin requires an exact DER match")
    func serverCertificatePinMatch() {
        let pinned = Data([0x30, 0x82, 0x01])

        #expect(GameStreamHTTPTransport.serverCertificateMatchesPin(
            presented: pinned,
            pinned: pinned
        ))
        #expect(!GameStreamHTTPTransport.serverCertificateMatchesPin(
            presented: Data([0x30, 0x82, 0x02]),
            pinned: pinned
        ))
        #expect(!GameStreamHTTPTransport.serverCertificateMatchesPin(
            presented: nil,
            pinned: pinned
        ))
        #expect(!GameStreamHTTPTransport.serverCertificateMatchesPin(
            presented: pinned,
            pinned: nil
        ))
    }

    @Test("the public-key pin hash is a stable SHA-256 of the certificate's SPKI")
    func pinHashIsStableSha256() throws {
        let identity = try ClientIdentity.generate()

        let first = try #require(GameStreamHTTPTransport.publicKeyPinHash(for: Data(identity.certificateDER)))
        let second = GameStreamHTTPTransport.publicKeyPinHash(for: Data(identity.certificateDER))

        #expect(first == second)
        // base64 of a SHA-256 digest is 44 characters.
        #expect(first.count == 44)
    }

    @Test("a secure request before a pin is captured fails closed")
    func secureRequestWithoutPinFailsClosed() async throws {
        let identity = try ClientIdentity.generate()
        let transport = GameStreamHTTPTransport(host: "192.0.2.1", identity: identity,
                                                curlExecutable: makeFakeCurl(status: "200", body: ""))

        await #expect(throws: PairingError.serverVerificationFailed) {
            _ = try await transport.get(secure: true, path: "applist",
                                        query: [URLQueryItem(name: "uniqueid", value: "u1")])
        }
    }

    @Test("GET drives curl with the pin and client certificate and returns the body")
    func getDrivesCurlWithPinAndClientCert() async throws {
        let identity = try ClientIdentity.generate()
        let log = tempFile("curl-args")
        let transport = GameStreamHTTPTransport(
            host: "192.0.2.1", identity: identity,
            curlExecutable: makeFakeCurl(status: "200", body: "applist-xml", logFile: log))
        transport.setPinnedServerCertificate([UInt8](identity.certificateDER))

        let data = try await transport.get(secure: true, path: "applist",
                                           query: [URLQueryItem(name: "uniqueid", value: "u1")])

        #expect(String(data: data, encoding: .utf8) == "applist-xml")
        let recorded = try String(contentsOf: log, encoding: .utf8)
        #expect(recorded.contains("--pinnedpubkey"))
        #expect(recorded.contains("sha256//"))
        #expect(recorded.contains("--cert"))
        #expect(recorded.contains("--key"))
        #expect(recorded.contains("-k"))
        #expect(recorded.contains("https://192.0.2.1:47984/applist?uniqueid=u1"))
    }

    @Test("POST sends the body via --data-binary")
    func postSendsBody() async throws {
        let identity = try ClientIdentity.generate()
        let log = tempFile("curl-args")
        let transport = GameStreamHTTPTransport(
            host: "192.0.2.1", identity: identity,
            curlExecutable: makeFakeCurl(status: "200", body: "ok", logFile: log))
        transport.setPinnedServerCertificate([UInt8](identity.certificateDER))

        let data = try await transport.post(
            secure: true, path: "actions/clipboard",
            query: [URLQueryItem(name: "type", value: "text")],
            body: Data("hello".utf8))

        #expect(String(data: data, encoding: .utf8) == "ok")
        let recorded = try String(contentsOf: log, encoding: .utf8)
        #expect(recorded.contains("--data-binary"))
        #expect(recorded.contains("https://192.0.2.1:47984/actions/clipboard?type=text"))
    }

    @Test("plain HTTP requests skip the TLS arguments")
    func plainHTTPNeedsNoTLSArgs() async throws {
        let identity = try ClientIdentity.generate()
        let log = tempFile("curl-args")
        let transport = GameStreamHTTPTransport(
            host: "192.0.2.1", identity: identity,
            curlExecutable: makeFakeCurl(status: "200", body: "ok", logFile: log))

        let data = try await transport.get(secure: false, path: "pair",
                                           query: [URLQueryItem(name: "phrase", value: "getservercert")])

        #expect(String(data: data, encoding: .utf8) == "ok")
        let recorded = try String(contentsOf: log, encoding: .utf8)
        #expect(!recorded.contains("--pinnedpubkey"))
        #expect(!recorded.contains("--cert"))
        #expect(!recorded.contains("-k"))
        #expect(recorded.contains("http://192.0.2.1:47989/pair?phrase=getservercert"))
    }

    @Test("a pin mismatch (curl exit 90) maps to server verification failure")
    func pinMismatchMapsToServerVerificationFailed() async throws {
        let identity = try ClientIdentity.generate()
        let transport = GameStreamHTTPTransport(
            host: "192.0.2.1", identity: identity,
            curlExecutable: makeFakeCurl(status: "", body: "", exitCode: 90))
        transport.setPinnedServerCertificate([UInt8](identity.certificateDER))

        await #expect(throws: PairingError.serverVerificationFailed) {
            _ = try await transport.get(secure: true, path: "applist", query: [])
        }
    }

    @Test("a non-2xx HTTP status maps to the http status error")
    func httpErrorStatusMaps() async throws {
        let identity = try ClientIdentity.generate()
        let transport = GameStreamHTTPTransport(
            host: "192.0.2.1", identity: identity,
            curlExecutable: makeFakeCurl(status: "404", body: "not found"))
        transport.setPinnedServerCertificate([UInt8](identity.certificateDER))

        await #expect(throws: PairingError.httpStatus(404)) {
            _ = try await transport.get(secure: true, path: "applist", query: [])
        }
    }

    private func tempFile(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }

    /// Writes an executable fake curl that records its arguments to `logFile`, writes `body` to the
    /// `-o` output path, prints `status` (the `%{http_code}` value) to stdout, and exits with
    /// `exitCode`.
    private func makeFakeCurl(status: String, body: String, exitCode: Int = 0, logFile: URL? = nil) -> URL {
        let scriptURL = tempFile("fake-curl")
        let logPath = logFile?.path ?? "/dev/null"
        let script = """
        #!/bin/sh
        echo "$@" >> "\(logPath)"
        prev=""
        for a in "$@"; do
          if [ "$prev" = "-o" ] && [ -n "$a" ]; then printf '%s' "\(body)" > "$a"; fi
          prev="$a"
        done
        printf '%s' "\(status)"
        exit \(exitCode)
        """
        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }
}