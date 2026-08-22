import Foundation
import Network

public struct DiscoveredService: Sendable, Equatable, Hashable {
    public let name: String
    public let type: String
    public let domain: String
    public init(name: String, type: String, domain: String) {
        self.name = name
        self.type = type
        self.domain = domain
    }
}

public struct ResolvedEndpoint: Sendable, Equatable {
    public let host: String
    public let port: UInt16
    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func tryFire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

/// Bonjour discovery via `NWBrowser`, with AWDL peer-to-peer interfaces excluded.
public actor HostBrowser {
    /// GameStream hosts advertise under this Bonjour service type.
    public static let serviceType = "_nvstream._tcp"

    public init() {}

    public func discover(forSeconds seconds: Double = 5) async -> [DiscoveredService] {
        await withCheckedContinuation { (cont: CheckedContinuation<[DiscoveredService], Never>) in
            let params = NWParameters.tcp
            params.includePeerToPeer = false  // never ride AWDL
            let browser = NWBrowser(
                for: .bonjour(type: Self.serviceType, domain: nil), using: params)
            let latch = Latch()
            let queue = DispatchQueue(label: "asteria.discovery.browse")

            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + seconds) {
                let services: [DiscoveredService] = browser.browseResults.compactMap { result in
                    if case let .service(name, type, domain, _) = result.endpoint {
                        return DiscoveredService(name: name, type: type, domain: domain)
                    }
                    return nil
                }
                browser.cancel()
                if latch.tryFire() { cont.resume(returning: services) }
            }
        }
    }

    public func resolve(_ service: DiscoveredService, timeout: Double = 5) async -> ResolvedEndpoint? {
        await withCheckedContinuation { (cont: CheckedContinuation<ResolvedEndpoint?, Never>) in
            let endpoint = NWEndpoint.service(
                name: service.name, type: service.type, domain: service.domain, interface: nil)
            let params = NWParameters.tcp
            params.includePeerToPeer = false
            let conn = NWConnection(to: endpoint, using: params)
            let latch = Latch()
            let queue = DispatchQueue(label: "asteria.discovery.resolve")

            @Sendable func finish(_ value: ResolvedEndpoint?) {
                conn.cancel()
                if latch.tryFire() { cont.resume(returning: value) }
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port) = conn.currentPath?.remoteEndpoint {
                        finish(ResolvedEndpoint(host: Self.hostString(host), port: port.rawValue))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let a): return Self.stripZone("\(a)")
        case .ipv6(let a): return Self.stripZone("\(a)")
        case .name(let n, _): return n
        @unknown default: return "\(host)"
        }
    }

    /// Strips the `%interface` scope suffix that Network.framework appends (e.g. "10.0.0.2%en0").
    static func stripZone(_ s: String) -> String {
        String(s.prefix { $0 != "%" })
    }
}
