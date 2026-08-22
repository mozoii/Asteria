import Foundation
import Testing
@testable import AsteriaModel

@Suite("Discovery reconciliation")
struct RosterReconcilerTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("New sighting is appended as an unpaired host")
    func appendsNew() {
        let sighting = DiscoverySighting(uniqueId: "uid-1", name: "PC", address: "10.0.0.5",
                                         hostSoftware: .sunshineCompatible, source: .bonjour)
        let result = RosterReconciler.reconcile(
            roster: [], sightings: [sighting], now: now, makeID: { "configuration-1" })
        #expect(result.count == 1)
        #expect(result[0].id == "configuration-1")
        #expect(result[0].hostUniqueId == "uid-1")
        #expect(result[0].hostSoftware == .sunshineCompatible)
        #expect(result[0].name == "PC")
        #expect(result[0].address == "10.0.0.5")
        #expect(result[0].isPaired == false)
        #expect(result[0].lastSeen == now)
    }

    @Test("Existing host matched by uniqueId refreshes address and lastSeen")
    func matchByUniqueId() {
        let existing = HostRecord(id: "client-1", hostUniqueId: "uid-1", name: "Old",
                                  address: "10.0.0.5", isPaired: true)
        let sighting = DiscoverySighting(uniqueId: "uid-1", name: "PC", address: "10.0.0.9", source: .bonjour)
        let result = RosterReconciler.reconcile(roster: [existing], sightings: [sighting], now: now)
        #expect(result.count == 1)
        #expect(result[0].address == "10.0.0.9")
        #expect(result[0].lastSeen == now)
        #expect(result[0].isPaired == true)
    }

    @Test("Placeholder records keep their local id and adopt the host uniqueId")
    func adoptsUniqueId() {
        let placeholder = HostRecord(id: "temp-uuid", name: "Manual", address: "10.0.0.5",
                                     manualAddress: "10.0.0.5", isPaired: false)
        let sighting = DiscoverySighting(uniqueId: "real-uid", name: "PC", address: "10.0.0.5", source: .manual)
        let result = RosterReconciler.reconcile(roster: [placeholder], sightings: [sighting], now: now)
        #expect(result.count == 1)
        #expect(result[0].id == "temp-uuid")
        #expect(result[0].hostUniqueId == "real-uid")
        #expect(result[0].manualAddress == "10.0.0.5")

        let paired = HostRecord(id: "client-1", hostUniqueId: "paired-uid", name: "PC",
                                address: "10.0.0.5", isPaired: true)
        let s2 = DiscoverySighting(uniqueId: "different", name: "PC", address: "10.0.0.5", source: .bonjour)
        let r2 = RosterReconciler.reconcile(roster: [paired], sightings: [s2], now: now)
        #expect(r2.count == 1)
        #expect(r2[0].id == "client-1")
        #expect(r2[0].hostUniqueId == "different")
    }

    @Test("Manual sighting without uniqueId matches an existing host by address")
    func matchByAddress() {
        let existing = HostRecord(id: "uid-1", name: "PC", address: "10.0.0.5")
        let sighting = DiscoverySighting(uniqueId: nil, name: "", address: "10.0.0.5", source: .manual)
        let result = RosterReconciler.reconcile(roster: [existing], sightings: [sighting], now: now)
        #expect(result.count == 1)
        #expect(result[0].id == "uid-1")
        #expect(result[0].manualAddress == "10.0.0.5")
    }

    @Test("Manual host added before any poll gets a generated id and address-as-name")
    func manualPlaceholderId() {
        let sighting = DiscoverySighting(uniqueId: nil, name: "", address: "10.0.0.42", source: .manual)
        let result = RosterReconciler.reconcile(roster: [], sightings: [sighting], now: now, makeID: { "gen-1" })
        #expect(result[0].id == "gen-1")
        #expect(result[0].name == "10.0.0.42")
        #expect(result[0].manualAddress == "10.0.0.42")
    }

    @Test("One host sighting refreshes every client configuration for that host")
    func refreshesDuplicateClientConfigurations() {
        let first = HostRecord(id: "client-1", hostUniqueId: "host-1", name: "Old",
                               address: "10.0.0.4", isPaired: true)
        let second = HostRecord(id: "client-2", hostUniqueId: "host-1", name: "Custom",
                                customName: "Desk", address: "10.0.0.4", isPaired: true)
        let sighting = DiscoverySighting(uniqueId: "host-1", name: "PC", address: "10.0.0.9",
                                         hostSoftware: .apolloFamily, source: .bonjour)

        let result = RosterReconciler.reconcile(roster: [first, second], sightings: [sighting], now: now)

        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.address == "10.0.0.9" })
        #expect(result.allSatisfy { $0.hostSoftware == .apolloFamily })
        #expect(result[1].displayName == "Desk")
    }
}

@Suite("Host availability & manual address")
struct HostAvailabilityTests {
    @Test("Availability folds reachability and busy state")
    func availability() {
        #expect(HostAvailability.from(reachable: false, isBusy: false) == .offline)
        #expect(HostAvailability.from(reachable: false, isBusy: true) == .offline)   // busy requires reachable
        #expect(HostAvailability.from(reachable: true, isBusy: false) == .online)
        #expect(HostAvailability.from(reachable: true, isBusy: true) == .busy)
    }

    @Test("Manual address strips scheme, trailing slash, and whitespace")
    func normalize() {
        #expect(ManualHostAddress.normalize("  https://192.168.3.63/  ") == "192.168.3.63")
        #expect(ManualHostAddress.normalize("desktop-en34reh") == "desktop-en34reh")
        #expect(ManualHostAddress.normalize("   ") == nil)
        #expect(ManualHostAddress.normalize("") == nil)
    }
}
