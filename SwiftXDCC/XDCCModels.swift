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

    init(id: UUID = UUID(),
         hostname: String,
         channels: [XDCCChannel],
         isPredefined: Bool = false) {
        self.id = id
        self.hostname = hostname
        self.channels = channels
        self.isPredefined = isPredefined
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
