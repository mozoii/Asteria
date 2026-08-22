import Testing
@testable import GameStreamProtocol

@Suite("Host-Compatible FEC Recovery")
struct HostFECRecoveryTests {
    @Test("Video mode recovers the maximum number of missing data shards")
    func videoRecovery() throws {
        let data = makeData(count: 6, size: 32)
        let parity = [
            bytes("73f8a69abfa5b3e2f877d02fcb0c72904dfaa40f2a4185276de27f805a996d5d"),
            bytes("e8c7be65ba6556329da318d439d1352d37166fca15190f90320c62aedc7e1067"),
            bytes("1d17845ac812d22d76abb91ca47149aa79cf5cde4c4022edf22fc76282f5e803"),
        ]
        var shards = data + parity
        var present = [Bool](repeating: true, count: shards.count)
        for index in [0, 2, 5] {
            present[index] = false
            shards[index] = [UInt8](repeating: 0, count: 32)
        }
        let recovery = try HostFECRecovery(mode: .video(dataShards: 6, parityShards: 3))

        try recovery.recover(shards: &shards, present: present, shardSize: 32)

        #expect(Array(shards.prefix(6)) == data)
    }

    @Test("Audio mode owns the Host parity matrix")
    func audioRecovery() throws {
        let data = makeData(count: 4, size: 32)
        let parity = [
            bytes("2b11bcdb530cd12cd910f681194fd5e5748e234bc38558c649803d4a89dff2b8"),
            bytes("80331cb89ca3cb5972bf9e2a1ea5b9e871406f280ca7cf73e22f10a48e35c391"),
        ]
        var shards = data + parity
        var present = [Bool](repeating: true, count: shards.count)
        present[1] = false
        present[3] = false
        shards[1] = [UInt8](repeating: 0, count: 32)
        shards[3] = [UInt8](repeating: 0, count: 32)
        let recovery = try HostFECRecovery(mode: .audio)

        try recovery.recover(shards: &shards, present: present, shardSize: 32)

        #expect(Array(shards.prefix(4)) == data)
    }

    @Test("Invalid video shard counts fail fast")
    func invalidVideoConfiguration() {
        #expect(throws: HostFECRecoveryError.invalidParameters) {
            try HostFECRecovery(mode: .video(dataShards: 0, parityShards: 2))
        }
        #expect(throws: HostFECRecoveryError.invalidParameters) {
            try HostFECRecovery(mode: .video(dataShards: 200, parityShards: 200))
        }
    }

    @Test("Recovery rejects an unrecoverable loss")
    func insufficientShards() throws {
        let recovery = try HostFECRecovery(mode: .video(dataShards: 5, parityShards: 2))
        var shards = makeData(count: 7, size: 16)
        var present = [Bool](repeating: true, count: 7)
        for index in [0, 1, 2] { present[index] = false }

        #expect(throws: HostFECRecoveryError.notEnoughShards) {
            try recovery.recover(shards: &shards, present: present, shardSize: 16)
        }
    }

    @Test("Complete data does not require parity")
    func completeDataIsUnchanged() throws {
        let recovery = try HostFECRecovery(mode: .video(dataShards: 4, parityShards: 2))
        var shards = makeData(count: 6, size: 16)
        let original = shards

        try recovery.recover(
            shards: &shards,
            present: [Bool](repeating: true, count: 6),
            shardSize: 16
        )

        #expect(shards == original)
    }

    private func makeData(count: Int, size: Int) -> [[UInt8]] {
        (0..<count).map { shard in
            (0..<size).map { byte in UInt8((shard * 31 + byte * 7) & 0xff) }
        }
    }

    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        }
    }
}
