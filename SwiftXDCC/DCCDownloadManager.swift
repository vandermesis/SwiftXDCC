//
//  DCCDownloadManager.swift
//  SwiftXDCC
//
//  Created by Codex on 13/06/2026.
//

import Foundation
import Network
import Observation

struct DCCOffer: Sendable {
    let fileName: String
    let host: String
    let port: UInt16
    let byteCount: Int64
    let bot: String
    let server: String
}

enum DownloadState: Equatable {
    case awaitingOffer
    case connecting
    case downloading
    case completed
    case failed(String)

    var label: String {
        switch self {
        case .awaitingOffer: "Waiting for bot"
        case .connecting: "Connecting"
        case .downloading: "Downloading"
        case .completed: "Completed"
        case .failed(let message): message
        }
    }
}

struct DownloadItem: Identifiable, Equatable {
    let id: UUID
    var fileName: String
    let bot: String
    let server: String
    var receivedBytes: Int64
    var totalBytes: Int64
    var state: DownloadState
    var fileURL: URL?

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(Double(receivedBytes) / Double(totalBytes), 1)
    }
}

@MainActor
@Observable
final class DCCDownloadManager {
    private static let bookmarkKey = "downloadDirectoryBookmark"

    private(set) var items: [DownloadItem] = []
    private(set) var directoryURL: URL

    private var pendingByBot: [String: UUID] = [:]
    private var sessions: [UUID: DCCTransferSession] = [:]
    private var directoryBookmark: Data?

    init() {
        let downloads = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")

        directoryURL = downloads
        directoryBookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey)

        if let bookmark = directoryBookmark,
           let resolved = Self.resolveBookmark(bookmark) {
            directoryURL = resolved
        }
    }

    func prepare(for result: SearchResult) {
        let id = UUID()
        let item = DownloadItem(
            id: id,
            fileName: result.fileName,
            bot: result.bot,
            server: result.server,
            receivedBytes: 0,
            totalBytes: 0,
            state: .awaitingOffer,
            fileURL: nil
        )
        items.removeAll {
            $0.bot.caseInsensitiveCompare(result.bot) == .orderedSame
                && $0.server.caseInsensitiveCompare(result.server) == .orderedSame
                && $0.state == .awaitingOffer
        }
        items.insert(item, at: 0)
        pendingByBot[key(bot: result.bot, server: result.server)] = id
    }

    func accept(_ offer: DCCOffer) {
        let pendingKey = key(bot: offer.bot, server: offer.server)
        let id = pendingByBot.removeValue(forKey: pendingKey) ?? UUID()

        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].fileName = offer.fileName
            items[index].totalBytes = offer.byteCount
            items[index].state = .connecting
        } else {
            items.insert(
                DownloadItem(
                    id: id,
                    fileName: offer.fileName,
                    bot: offer.bot,
                    server: offer.server,
                    receivedBytes: 0,
                    totalBytes: offer.byteCount,
                    state: .connecting,
                    fileURL: nil
                ),
                at: 0
            )
        }

        guard !DCCHostPolicy.isBlocked(offer.host) else {
            update(id) {
                $0.state = .failed("Refused offer from a private or loopback address (\(offer.host)).")
            }
            return
        }

        do {
            let destination = try makeDestination(for: offer.fileName)
            update(id) { $0.fileURL = destination.url }
            let owner = WeakDownloadManager(self)

            do {
                let session = try DCCTransferSession(
                    offer: offer,
                    destination: destination.url,
                    securityScopedDirectory: destination.securityScopedDirectory
                ) { event in
                    Task { @MainActor in
                        owner.value?.handle(event, for: id)
                    }
                }
                sessions[id] = session
                session.start()
            } catch {
                destination.securityScopedDirectory?.stopAccessingSecurityScopedResource()
                throw error
            }
        } catch {
            update(id) { $0.state = .failed(error.localizedDescription) }
        }
    }

    func setDirectory(_ url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw DCCDownloadError.directoryAccessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        directoryBookmark = bookmark
        directoryURL = url
    }

    func useDefaultDirectory() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        directoryBookmark = nil
        directoryURL = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    private func handle(_ event: DCCTransferEvent, for id: UUID) {
        // Terminal states are sticky. Events hop to the main actor in separate
        // tasks, so a late `progress`/`connected` can arrive after the session's
        // `completed`/`failed` and must not regress the row.
        if let item = items.first(where: { $0.id == id }) {
            switch item.state {
            case .completed, .failed:
                return
            default:
                break
            }
        }

        switch event {
        case .connected:
            update(id) { $0.state = .downloading }
        case .progress(let received):
            update(id) {
                $0.receivedBytes = received
                $0.state = .downloading
            }
        case .completed:
            update(id) {
                $0.receivedBytes = $0.totalBytes
                $0.state = .completed
            }
            sessions[id] = nil
        case .failed(let message):
            update(id) { $0.state = .failed(message) }
            sessions[id] = nil
        }
    }

    private func update(_ id: UUID, change: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func makeDestination(
        for offeredName: String
    ) throws -> (url: URL, securityScopedDirectory: URL?) {
        let directory: URL
        let scopedDirectory: URL?

        if let bookmark = directoryBookmark,
           let resolved = Self.resolveBookmark(bookmark),
           resolved.startAccessingSecurityScopedResource() {
            directory = resolved
            scopedDirectory = resolved
            directoryURL = resolved
        } else {
            directory = FileManager.default.urls(
                for: .downloadsDirectory,
                in: .userDomainMask
            ).first ?? directoryURL
            scopedDirectory = nil
        }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let sanitized = URL(fileURLWithPath: offeredName).lastPathComponent
        guard !sanitized.isEmpty, sanitized != ".", sanitized != ".." else {
            scopedDirectory?.stopAccessingSecurityScopedResource()
            throw DCCDownloadError.invalidFileName
        }

        var destination = directory.appendingPathComponent(sanitized)
        let stem = destination.deletingPathExtension().lastPathComponent
        let fileExtension = destination.pathExtension
        var suffix = 2

        while FileManager.default.fileExists(atPath: destination.path) {
            let nextName = fileExtension.isEmpty
                ? "\(stem) \(suffix)"
                : "\(stem) \(suffix).\(fileExtension)"
            destination = directory.appendingPathComponent(nextName)
            suffix += 1
        }

        return (destination, scopedDirectory)
    }

    private func key(bot: String, server: String) -> String {
        "\(server.lowercased())|\(bot.lowercased())"
    }

    private static func resolveBookmark(_ bookmark: Data) -> URL? {
        var stale = false
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }
}

private final class WeakDownloadManager: @unchecked Sendable {
    weak var value: DCCDownloadManager?

    init(_ value: DCCDownloadManager) {
        self.value = value
    }
}

enum DCCOfferParser {
    private static let expression = try! NSRegularExpression(
        pattern: #"^DCC\s+SEND\s+(?:"([^"]+)"|(\S+))\s+(\S+)\s+(\d+)\s+(\d+)"#,
        options: [.caseInsensitive]
    )

    static func parse(_ text: String, bot: String, server: String) -> DCCOffer? {
        let cleaned = text.trimmingCharacters(
            in: CharacterSet(charactersIn: "\u{01}").union(.whitespacesAndNewlines)
        )
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        guard let match = expression.firstMatch(in: cleaned, range: range),
              let fileName = capture(1, from: match, in: cleaned)
                ?? capture(2, from: match, in: cleaned),
              let hostToken = capture(3, from: match, in: cleaned),
              let portText = capture(4, from: match, in: cleaned),
              let sizeText = capture(5, from: match, in: cleaned),
              let port = UInt16(portText),
              let byteCount = Int64(sizeText),
              let host = host(from: hostToken) else {
            return nil
        }

        return DCCOffer(
            fileName: URL(fileURLWithPath: fileName).lastPathComponent,
            host: host,
            port: port,
            byteCount: byteCount,
            bot: bot,
            server: server
        )
    }

    private static func capture(
        _ index: Int,
        from match: NSTextCheckingResult,
        in text: String
    ) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }

    private static func host(from token: String) -> String? {
        if token.contains(".") {
            return token
        }
        guard let value = UInt32(token) else { return nil }
        return [
            value >> 24,
            (value >> 16) & 0xff,
            (value >> 8) & 0xff,
            value & 0xff
        ]
        .map(String.init)
        .joined(separator: ".")
    }
}

/// Guards against DCC offers that point at our own network. A public bot's
/// offer should resolve to a routable address; loopback, private (RFC-1918),
/// link-local, or unspecified hosts are a red flag (e.g. an attacker steering a
/// transfer at a service on the user's machine or LAN), so they're refused.
///
/// The offer parser already rejects any host without a `.`, so IPv6 literals and
/// bare `localhost` never reach here; this focuses on dotted IPv4.
enum DCCHostPolicy {
    static func isBlocked(_ host: String) -> Bool {
        if host.caseInsensitiveCompare("localhost") == .orderedSame { return true }
        guard let octets = ipv4Octets(host) else { return false }
        if octets[0] == 0 || octets[0] == 127 || octets[0] == 10 { return true }
        if octets[0] == 172, (16...31).contains(octets[1]) { return true }
        if octets[0] == 192, octets[1] == 168 { return true }
        if octets[0] == 169, octets[1] == 254 { return true }
        return false
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return nil
        }
        return octets
    }
}

private enum DCCTransferEvent: Sendable {
    case connected
    case progress(Int64)
    case completed
    case failed(String)
}

private enum DCCDownloadError: LocalizedError {
    case directoryAccessDenied
    case invalidFileName
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .directoryAccessDenied:
            "The selected download folder could not be accessed."
        case .invalidFileName:
            "The bot offered an invalid file name."
        case .connectionClosed:
            "The bot closed the transfer before the file was complete."
        }
    }
}

private final class DCCTransferSession: @unchecked Sendable {
    private let offer: DCCOffer
    private let destination: URL
    private let securityScopedDirectory: URL?
    private let onEvent: @Sendable (DCCTransferEvent) -> Void
    private let queue = DispatchQueue(label: "SwiftXDCC.DCCTransfer")

    /// Fail an offer that never connects (e.g. NAT-blocked / unreachable host)
    /// instead of leaving the row stuck on "Connecting".
    private static let connectTimeout: DispatchTimeInterval = .seconds(20)

    private var connection: NWConnection?
    private var fileHandle: FileHandle?
    private var receivedBytes: Int64 = 0
    private var didConnect = false
    private var isFinished = false

    init(
        offer: DCCOffer,
        destination: URL,
        securityScopedDirectory: URL?,
        onEvent: @escaping @Sendable (DCCTransferEvent) -> Void
    ) throws {
        self.offer = offer
        self.destination = destination
        self.securityScopedDirectory = securityScopedDirectory
        self.onEvent = onEvent

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: destination)
    }

    func start() {
        guard let port = NWEndpoint.Port(rawValue: offer.port) else {
            finish(.failed("Invalid DCC port \(offer.port)."))
            return
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(offer.host),
            port: port,
            using: .tcp
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state)
        }
        connection.start(queue: queue)

        queue.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak self] in
            guard let self, !self.isFinished, !self.didConnect else { return }
            self.finish(.failed("Timed out connecting to \(self.offer.host)."))
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            didConnect = true
            onEvent(.connected)
            receiveNextChunk()
        case .waiting(let error):
            // The path can't be established (refused / unreachable / NAT-blocked);
            // NWConnection would otherwise retry indefinitely, so fail promptly.
            finish(.failed(error.localizedDescription))
        case .failed(let error):
            finish(.failed(error.localizedDescription))
        case .cancelled:
            if !isFinished {
                finish(.failed("Download cancelled."))
            }
        default:
            break
        }
    }

    private func receiveNextChunk() {
        connection?.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                // Never write past the offered size: a misbehaving bot can send
                // extra bytes, and the final file must match the offer exactly.
                let remaining = self.offer.byteCount - self.receivedBytes
                let usable = remaining > 0 ? data.prefix(Int(min(remaining, Int64(data.count)))) : Data()
                if !usable.isEmpty {
                    do {
                        try self.fileHandle?.write(contentsOf: usable)
                        self.receivedBytes += Int64(usable.count)
                        self.sendAcknowledgement()
                        self.onEvent(.progress(self.receivedBytes))
                    } catch {
                        self.finish(.failed(error.localizedDescription))
                        return
                    }
                }
            }

            if self.receivedBytes >= self.offer.byteCount {
                self.finish(.completed)
            } else if let error {
                self.finish(.failed(error.localizedDescription))
            } else if isComplete {
                self.finish(.failed(DCCDownloadError.connectionClosed.localizedDescription))
            } else {
                self.receiveNextChunk()
            }
        }
    }

    private func sendAcknowledgement() {
        var acknowledgement = UInt32(truncatingIfNeeded: receivedBytes).bigEndian
        let data = Data(bytes: &acknowledgement, count: MemoryLayout<UInt32>.size)
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.finish(.failed(error.localizedDescription))
            }
        })
    }

    private func finish(_ event: DCCTransferEvent) {
        guard !isFinished else { return }
        isFinished = true

        try? fileHandle?.close()
        fileHandle = nil

        if case .failed = event {
            try? FileManager.default.removeItem(at: destination)
        }

        connection?.cancel()
        connection = nil
        securityScopedDirectory?.stopAccessingSecurityScopedResource()
        onEvent(event)
    }
}
