import Foundation
import Testing
import AsteriaCore
@testable import Pairing

@Suite("Host response golden fixtures")
struct HostResponseFixtureTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func parsesRealApplistAndUnescapesTitles() throws {
        let apps = AppListParser.parse(try fixture("applist"))
        #expect(apps.count == 4)
        #expect(apps.first(where: { $0.id == "1639965107" })?.title == "Desktop")
        #expect(apps.first(where: { $0.id == "100000002" })?.title == "Tom & Jerry")
    }

    @Test func parsesRealLaunchResponse() throws {
        let session = try LaunchSession(parsingLaunch: try fixture("launch"))
        #expect(session.rtspSessionURL == "rtsp://10.0.0.2:48010")
        #expect(session.gameSession == 1)
    }

    @Test func parsesRealCancelResponse() throws {
        #expect(HostClient.parseCancel(try fixture("cancel")) == true)
    }

    @Test func readsRealGetservercertEnvelope() throws {
        let xml = try FlatXML(parsing: try fixture("getservercert"))
        #expect(xml.int("paired") == 1)
        let plaincert = try #require(xml.value("plaincert"))
        #expect(Hex.decode(plaincert) != nil)
    }
}
