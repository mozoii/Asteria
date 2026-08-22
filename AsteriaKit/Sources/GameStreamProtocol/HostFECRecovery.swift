import CNanors
import Foundation

enum HostFECRecoveryError: Error, Equatable {
    case invalidParameters
    case notEnoughShards
    case recoveryFailed
}

final class HostFECRecovery {
    enum Mode {
        case audio
        case video(dataShards: Int, parityShards: Int)
    }

    private static let constructionLock = NSLock()

    private let codec: UnsafeMutablePointer<reed_solomon>
    private let dataShards: Int
    private let parityShards: Int
    private var totalShards: Int { dataShards + parityShards }

    init(mode: Mode) throws {
        let configuration = Self.configuration(for: mode)
        guard configuration.data > 0,
              configuration.parity > 0,
              configuration.data + configuration.parity <= Int(DATA_SHARDS_MAX) else {
            throw HostFECRecoveryError.invalidParameters
        }
        Self.constructionLock.lock()
        defer { Self.constructionLock.unlock() }
        guard let codec = reed_solomon_new(
            Int32(configuration.data),
            Int32(configuration.parity)
        ) else {
            throw HostFECRecoveryError.invalidParameters
        }
        if case .audio = mode, asteria_configure_audio_fec(codec) != 0 {
            reed_solomon_release(codec)
            throw HostFECRecoveryError.invalidParameters
        }
        self.codec = codec
        self.dataShards = configuration.data
        self.parityShards = configuration.parity
    }

    deinit {
        reed_solomon_release(codec)
    }

    func recover(shards: inout [[UInt8]], present: [Bool], shardSize: Int) throws {
        guard shardSize > 0,
              shards.count == totalShards,
              present.count == totalShards else {
            throw HostFECRecoveryError.invalidParameters
        }
        guard present.lazy.filter({ $0 }).count >= dataShards else {
            throw HostFECRecoveryError.notEnoughShards
        }
        if present[..<dataShards].allSatisfy({ $0 }) { return }

        let (capacity, overflow) = totalShards.multipliedReportingOverflow(by: shardSize)
        guard !overflow else { throw HostFECRecoveryError.invalidParameters }
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { scratch.deallocate() }
        var pointers = [UnsafeMutablePointer<UInt8>?](repeating: nil, count: totalShards)
        var missing = [UInt8](repeating: 1, count: totalShards)
        copy(shards, present: present, shardSize: shardSize, into: scratch,
             pointers: &pointers, missing: &missing)

        let result = pointers.withUnsafeMutableBufferPointer { shardPointers in
            missing.withUnsafeMutableBufferPointer { missingShards in
                reed_solomon_decode(
                    codec,
                    shardPointers.baseAddress,
                    missingShards.baseAddress,
                    Int32(totalShards),
                    Int32(shardSize)
                )
            }
        }
        guard result == 0 else { throw HostFECRecoveryError.recoveryFailed }
        for index in 0..<dataShards where !present[index] {
            shards[index] = Array(
                UnsafeBufferPointer(start: scratch + index * shardSize, count: shardSize)
            )
        }
    }

    private static func configuration(for mode: Mode) -> (data: Int, parity: Int) {
        switch mode {
        case .audio:
            return (4, 2)
        case let .video(dataShards, parityShards):
            return (dataShards, parityShards)
        }
    }

    private func copy(
        _ shards: [[UInt8]],
        present: [Bool],
        shardSize: Int,
        into scratch: UnsafeMutablePointer<UInt8>,
        pointers: inout [UnsafeMutablePointer<UInt8>?],
        missing: inout [UInt8]
    ) {
        for index in 0..<totalShards {
            let destination = scratch + index * shardSize
            pointers[index] = destination
            destination.update(repeating: 0, count: shardSize)
            guard present[index] else { continue }
            missing[index] = 0
            let count = min(shardSize, shards[index].count)
            shards[index].withUnsafeBytes { bytes in
                guard let source = bytes.baseAddress else { return }
                destination.update(
                    from: source.assumingMemoryBound(to: UInt8.self),
                    count: count
                )
            }
        }
    }
}
