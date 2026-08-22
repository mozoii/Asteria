import Foundation
import AsteriaCore

public enum ServerInfoParseError: Error, Equatable {
    case malformed(String)
}

/// Parses the flat `/serverinfo` XML into a `ServerInfo`.
public enum ServerInfoParser {
    public static func parse(_ data: Data) throws -> ServerInfo {
        let xml: FlatXML
        do { xml = try FlatXML(parsing: data) }
        catch { throw ServerInfoParseError.malformed("\(error)") }

        func value(_ key: String) -> String? { xml.value(key) }
        func required(_ key: String) throws -> String {
            guard let v = value(key), !v.isEmpty else { throw ServerInfoParseError.malformed("missing <\(key)>") }
            return v
        }

        return ServerInfo(
            statusCode: xml.rootStatus?.code ?? 0,
            hostname: try required("hostname"),
            appVersion: value("appversion") ?? "",
            gfeVersion: value("GfeVersion"),
            sunshineVersion: value("SunshineVersion"),
            uniqueId: try required("uniqueid"),
            httpsPort: value("HttpsPort").flatMap { UInt16($0) } ?? 47984,
            externalPort: value("ExternalPort").flatMap { UInt16($0) } ?? 47989,
            mac: value("mac"),
            localIP: value("LocalIP"),
            maxLumaPixelsHEVC: value("MaxLumaPixelsHEVC").flatMap { Int($0) },
            serverCodecModeSupport: value("ServerCodecModeSupport").flatMap { Int($0) },
            pairStatus: value("PairStatus").flatMap { Int($0) } ?? 0,
            currentGame: value("currentgame").flatMap { Int($0) } ?? 0,
            state: value("state") ?? "",
            permission: value("Permission").flatMap { UInt32($0) }
        )
    }
}
