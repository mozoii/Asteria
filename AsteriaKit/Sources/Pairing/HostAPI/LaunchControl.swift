import Foundation
import GameStreamProtocol
import AsteriaCore

/// RTSP session from /launch or /resume.
public struct LaunchSession: Sendable, Equatable {
    public let rtspSessionURL: String
    public let gameSession: Int

    public init(rtspSessionURL: String, gameSession: Int) {
        self.rtspSessionURL = rtspSessionURL
        self.gameSession = gameSession
    }

    public init(parsingLaunch data: Data) throws {
        try self.init(parsing: data, flagTag: "gamesession")
    }

    public init(parsingResume data: Data) throws {
        try self.init(parsing: data, flagTag: "resume")
    }

    private init(parsing data: Data, flagTag: String) throws {
        let xml = try? FlatXML(parsing: data)
        // Preserve host error message (e.g. 403 "lacks Launch applications permission") for the UI.
        if let status = xml?.rootStatus, status.code != 200 {
            throw PairingError.launchRejected(code: status.code, message: status.message ?? "The PC rejected the request.")
        }
        guard let url = xml?.value("sessionUrl0"), !url.isEmpty,
              xml?.int(flagTag) == 1 else {
            throw PairingError.malformedResponse("launch: missing sessionUrl0/\(flagTag)")
        }
        self.rtspSessionURL = url
        self.gameSession = 1
    }
}
