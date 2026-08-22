import Foundation
import Testing
import AsteriaCore
@testable import AsteriaModel

@Suite("Roster mutations")
struct RosterMutationTests {
    @Test("markPaired pins the cert and fingerprint")
    func pairingState() {
        var host = HostRecord(id: "uid", name: "PC", address: "10.0.0.5")
        #expect(host.isPaired == false)
        let fingerprint = ClientFingerprint(rawValue: String(repeating: "a", count: 64))!
        host.markPaired(pinnedCertificate: Data([1, 2, 3]), clientFingerprint: fingerprint)
        #expect(host.isPaired)
        #expect(host.pinnedCertificate == Data([1, 2, 3]))
        #expect(host.clientFingerprint == fingerprint)
    }

    @Test("upsertHost replaces by id and appends new")
    func upsert() {
        var doc = LibraryDocument(hosts: [HostRecord(id: "a", name: "A", address: "1")])
        doc.upsertHost(HostRecord(id: "a", name: "A2", address: "1"))
        #expect(doc.hosts.count == 1)
        #expect(doc.hosts[0].name == "A2")
        doc.upsertHost(HostRecord(id: "b", name: "B", address: "2"))
        #expect(doc.hosts.count == 2)
        #expect(doc.hosts.map(\.id) == ["a", "b"])
    }
}
