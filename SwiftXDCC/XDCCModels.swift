//
//  XDCCModels.swift
//  SwiftXDCC
//
//  Created by Marek Skrzelowski on 13/06/2026.
//

import Foundation

/// A server the app connects to. Built-in servers are seeded from ``XDCCHost``;
/// users can add their own with custom channels. Custom servers are persisted.
struct XDCCServer: Identifiable, Hashable, Codable {
    let id: UUID
    var hostname: String
    var channels: [XDCCChannel]
    let isPredefined: Bool
    /// Whether the user has selected this server to connect to. Session-only
    /// (not persisted) and defaults to on.
    var isEnabled: Bool = true
    /// NickServ command that registers this connection's CertFP fingerprint.
    /// Networks differ (e.g. Rizon has no `CERT`), so it is editable. `%fp` is
    /// replaced with the certificate fingerprint. Persisted per host by the
    /// client (kept out of the struct's Codable form, like ``isEnabled``).
    var certificateCommand: String = "CERT ADD"

    // `isEnabled`/`certificateCommand` are managed outside the struct's JSON.
    private enum CodingKeys: String, CodingKey {
        case id, hostname, channels, isPredefined
    }

    init(id: UUID = UUID(),
         hostname: String,
         channels: [XDCCChannel],
         isPredefined: Bool = false,
         isEnabled: Bool = true,
         certificateCommand: String = "CERT ADD") {
        self.id = id
        self.hostname = hostname
        self.channels = channels
        self.isPredefined = isPredefined
        self.isEnabled = isEnabled
        self.certificateCommand = certificateCommand
    }
}

extension XDCCServer {
    /// Built-in servers shipped with the app, seeded from ``XDCCHost``.
    static var predefined: [XDCCServer] {
        XDCCHost.allCases.map {
            XDCCServer(hostname: $0.name, channels: $0.channels, isPredefined: true)
        }
    }

    /// Channels on this server that accept search queries.
    var searchChannels: [XDCCChannel] {
        channels.filter { $0.type.contains(.search) }
    }

    /// All configured channels. Bots often require users to be present in their
    /// download channel before accepting an XDCC request.
    var connectionChannels: [XDCCChannel] {
        channels
    }
}

/// A single console log line, tagged with the network it came from (if any) so
/// the UI can colour-code per network. `source` is `nil` for app-level lines.
struct LogEntry: Identifiable, Hashable {
    let id = UUID()
    let message: String
    let source: String?
}

/// A single XDCC package returned from a search.
struct SearchResult: Identifiable, Hashable {
    let id = UUID()
    let fileName: String
    let size: String
    /// Nick of the bot advertising the pack.
    let bot: String
    /// Pack number requested via `xdcc send #<packNumber>`.
    let packNumber: Int
    /// Hostname of the server where the package was found.
    let server: String
    /// Channel (hash name) where the package was found.
    let channel: String
}
