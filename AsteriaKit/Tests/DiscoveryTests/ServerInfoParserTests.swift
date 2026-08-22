import Foundation
import Testing
@testable import Discovery

@Suite("ServerInfo parsing (real Sunshine fixture)")
struct ServerInfoParserTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func parsesSunshineServerInfo() throws {
        let info = try ServerInfoParser.parse(try fixture("serverinfo-sunshine"))
        #expect(info.statusCode == 200)
        #expect(info.hostname == "TESTHOST")
        #expect(info.uniqueId == "00000000-0000-0000-0000-000000000000")
        #expect(info.appVersion == "7.1.431.-1")
        #expect(info.gfeVersion == "3.23.0.74")
        #expect(info.httpsPort == 47984)
        #expect(info.externalPort == 47989)
        #expect(info.localIP == "10.0.0.2")
        #expect(info.serverCodecModeSupport == 1835777)
        #expect(info.state == "SUNSHINE_SERVER_FREE")
    }

    @Test func mainlineSunshineIsNotApollo() throws {
        let info = try ServerInfoParser.parse(try fixture("serverinfo-sunshine"))
        #expect(info.permission == nil)
        #expect(info.isApolloFamily == false)
    }

    @Test func apolloIsDetectedByPermissionField() throws {
        let info = try ServerInfoParser.parse(try fixture("serverinfo-apollo"))
        #expect(info.hostname == "APOLLOHOST")
        #expect(info.permission == 805306367)
        #expect(info.isApolloFamily == true)
        #expect(info.isFoundationSunshine == false)
    }

    @Test func foundationSunshineIsDetectedByVersionField() throws {
        let xml = Data("""
            <root status_code="200"><hostname>FOUNDATION</hostname><appversion>7.1.431.-1</appversion>
            <uniqueid>foundation-id</uniqueid><SunshineVersion>2026.515.84851</SunshineVersion></root>
            """.utf8)
        let info = try ServerInfoParser.parse(xml)

        #expect(info.sunshineVersion == "2026.515.84851")
        #expect(info.isFoundationSunshine == true)
        #expect(info.isApolloFamily == false)
    }

    @Test func derivesPairAndBusyFlags() throws {
        let info = try ServerInfoParser.parse(try fixture("serverinfo-sunshine"))
        #expect(info.pairStatus == 0)
        #expect(info.isPaired == false)
        #expect(info.currentGame == 0)
        #expect(info.isBusy == false)
    }

    @Test func rejectsMalformedXML() {
        let garbage = Data("<root><hostname>".utf8)
        #expect(throws: ServerInfoParseError.self) {
            try ServerInfoParser.parse(garbage)
        }
    }
}
