//
//  XDCCClient.swift
//  SwiftXDCC
//
//  Created by Marek Skrzelowski on 12/06/2026.
//

import Foundation
import NIO
@preconcurrency import NIOIRC
import NIOSSL

struct XDCCChannel: Identifiable, Hashable, Codable {
    let id: UUID = UUID()
    let name: String
    let type: [XDCCChannelType]

    // `id` is ephemeral identity, regenerated per launch, so it is not persisted.
    private enum CodingKeys: String, CodingKey {
        case name, type
    }

    var hashName: String {
        return "#\(name)"
    }
}

enum XDCCChannelType: String, CaseIterable, Codable {
    case download
    case search
    case request
}

enum XDCCHost: CaseIterable, Identifiable {
    case abjects
    case rizon
    case scene
    case abandoned
    case custom(name: String, channels: [XDCCChannel])

    var id: String {
        switch self {
        case .abjects, .rizon, .scene, .abandoned:
            return self.name
        case .custom(name: let name, channels: _):
            return name
        }
    }

    var name: String {
        switch self {
        case .abjects:
            return "irc.abjects.net"
        case .rizon:
            return "irc.rizon.net"
        case .scene:
            return "irc.scenep2p.net"
        case .abandoned:
            return "irc.abandoned-irc.net"
        case .custom(let name, _):
            return name
        }
    }

    var channels: [XDCCChannel] {
        switch self {
        case .abjects:
            return [
                .init(name: "beast-xdcc", type: [.download]),
                .init(name: "beast-chat", type: [.search, .request]),
                .init(name: "moviegods", type: [.download]),
                .init(name: "mg-chat", type: [.search]),
                .init(name: "mg-lounge", type: [.request])
            ]
        case .rizon:
            return [
                .init(name: "ELITEWAREZ", type: [.download]),
                .init(name: "elite-chat", type: [.search, .request]),
                .init(name: "Batcave", type: [.download]),
                .init(name: "Batcave-Chat", type: [.search, .request]),
                .init(name: "AsphyxiA", type: [.download, .search, .request]),
                .init(name: "1WAREZ", type: [.download]),
                .init(name: "1WAREZ-CHAT", type: [.search, .request])
            ]
        case .scene:
            return [
                .init(name: "THE.SOURCE", type: [.download]),
                .init(name: "The.Lounge", type: [.search]),
                .init(name: "The.Insiders", type: [.request])]
        case .abandoned:
            return [
                .init(name: "zombie-warez", type: [.download]),
                .init(name: "ZW-CHAT", type: [.search, .request])
            ]
        case .custom(_, let channels):
            return channels
        }
    }

    static var allCases: [XDCCHost] {
        return [.abjects, .rizon, .scene, .abandoned]
    }
}

/// Service that connects to every configured IRC server over TLS in parallel,
/// registers the nick (NickServ password or CertFP), joins each server's
/// channels, and searches the search-enabled channels for XDCC packages.
///
/// Shared connection parameters fall back to sensible defaults:
/// - `nick`: `"SwiftXDCC"`
/// - `password`: `"swiftxdcc@vandermesis.com"`
/// - `pemData`: when `nil`, NickServ registration uses the password only and the
///   TLS connection is anonymous (no client certificate). When set, the PEM
///   bytes are loaded as the client certificate/key for CertFP authentication.
///
/// Because the app runs in the App Sandbox, the PEM is supplied as raw bytes
/// (read from a user-selected file via a security-scoped resource) rather than a
/// file path the service would try to open itself.
@MainActor
@Observable
final class XDCCClient {

    enum Port: Int {
        case ssl = 6697
        case standard = 6666
    }

    enum Status: Equatable {
        case disconnected
        case connecting
        case registered
        case failed(String)
    }

    /// Events forwarded from a single server's NIO event loop back to the main actor.
    enum Event: Sendable {
        case registered
        case failed(String)
        case log(String)
    }

    /// Shared IRC identity used for every connection. Editable while disconnected.
    var nick: String
    var password: String
    let port: Int

    /// PEM bytes (certificate + private key) for CertFP. Set from a
    /// user-selected file before calling ``connect()``.
    var pemData: Data?

    /// Servers the app connects to: built-in plus any the user has added.
    /// Custom servers are persisted between launches.
    var servers: [XDCCServer] {
        didSet { saveCustomServers() }
    }

    /// Packages returned from the most recent search.
    private(set) var results: [SearchResult] = []
    private(set) var isSearching = false

    private(set) var status: Status = .disconnected
    private(set) var log: [String] = []

    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private static let customServersKey = "customServers"

    private var channelsByServer: [UUID: any Channel] = [:]
    private var registeredServers: Set<UUID> = []

    init(nick: String? = nil,
         password: String? = nil,
         pemData: Data? = nil,
         port: Port = .ssl
    ) {
        self.nick = nick ?? "SwiftXDCC"
        self.password = password ?? "swiftxdcc@vandermesis.com"
        self.pemData = pemData
        self.port = port.rawValue
        self.servers = XDCCServer.predefined + Self.loadCustomServers()
    }

    /// At least one server has completed registration.
    var isConnected: Bool { !registeredServers.isEmpty }

    // MARK: - Connection

    /// Connects to every server in ``servers`` in parallel. Each connection
    /// registers and then joins that server's channels via their hash names.
    func connect() {
        guard channelsByServer.isEmpty else { return }

        let sslContext: NIOSSLContext
        do {
            sslContext = try makeSSLContext()
        } catch {
            fail("TLS setup failed: \(error.localizedDescription)")
            return
        }

        status = .connecting
        registeredServers.removeAll()
        let usesCertificate = pemData != nil
        append("Connecting to \(servers.count) server(s) as \(nick)…")

        for server in servers {
            connect(to: server, sslContext: sslContext, usesCertificate: usesCertificate)
        }
    }

    private func connect(to server: XDCCServer,
                         sslContext: NIOSSLContext,
                         usesCertificate: Bool) {
        let serverID = server.id
        let hostname = server.hostname
        let config = SessionConfig(nick: nick,
                                   password: password,
                                   host: hostname,
                                   channels: server.channels.map(\.hashName),
                                   hasCertificate: usesCertificate)
        let onEvent: @Sendable (Event) -> Void = { [weak self] event in
            Task { @MainActor in self?.handle(event, from: serverID) }
        }
        let port = port
        append("[\(hostname)] Connecting (TLS, port \(port))…")

        Task {
            let bootstrap = ClientBootstrap(group: Self.group)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { channel in
                    do {
                        let tls = try NIOSSLClientHandler(context: sslContext,
                                                          serverHostname: hostname)
                        return channel.pipeline.addHandlers([
                            tls,
                            IRCChannelHandler(),
                            IRCSessionHandler(config: config, onEvent: onEvent)
                        ])
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }

            do {
                let channel = try await bootstrap.connect(host: hostname, port: port).get()
                self.channelsByServer[serverID] = channel
            } catch {
                self.handle(.failed("Connection failed: \(error.localizedDescription)"),
                            from: serverID)
            }
        }
    }

    func disconnect() {
        for channel in channelsByServer.values {
            channel.close(mode: .all, promise: nil)
        }
        channelsByServer.removeAll()
        registeredServers.removeAll()
        status = .disconnected
        append("Disconnected from all servers.")
    }

    // MARK: - Search

    /// Searches for `query` on every connected server, messaging only channels
    /// whose type includes ``XDCCChannelType/search``.
    ///
    /// - Note: Stage 1 returns mock results. The real per-network search-bot
    ///   command syntax and reply parsing are added once confirmed.
    func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard isConnected else {
            append("Connect to a server before searching.")
            return
        }

        isSearching = true
        results = []

        var targets: [(server: XDCCServer, channel: XDCCChannel)] = []
        for server in servers where registeredServers.contains(server.id) {
            for channel in server.searchChannels {
                targets.append((server, channel))
                append("Searching \"\(trimmed)\" on \(channel.hashName) (\(server.hostname))…")
            }
        }

        guard !targets.isEmpty else {
            isSearching = false
            append("No search-enabled channels on the connected servers.")
            return
        }

        Task {
            // Simulates the round-trip to the search bots.
            try? await Task.sleep(for: .milliseconds(400))
            self.results = Self.mockResults(for: trimmed, on: targets)
            self.isSearching = false
            self.append("Found \(self.results.count) result(s).")
        }
    }

    /// Issues the XDCC request for a result by messaging the bot. The DCC SEND
    /// file transfer itself is deferred to a later stage.
    func requestDownload(_ result: SearchResult) {
        append("Requesting \(result.fileName) — xdcc send #\(result.packNumber) from \(result.bot).")

        guard let server = servers.first(where: { $0.hostname == result.server }),
              let channel = channelsByServer[server.id],
              let bot = IRCNickName(result.bot) else {
            append("Not connected to \(result.server); download request not sent.")
            return
        }

        let message = IRCMessage(command: .PRIVMSG([.nickname(bot)],
                                                   "xdcc send #\(result.packNumber)"))
        channel.writeAndFlush(message, promise: nil)
    }

    /// Appends an informational line to the log (e.g. from the UI layer).
    func note(_ message: String) {
        append(message)
    }

    /// Clears the activity log.
    func clearLog() {
        log.removeAll()
    }

    // MARK: - TLS

    /// Builds the TLS client context, loading `pemData` as a client certificate
    /// and key (CertFP) when present, otherwise an anonymous client.
    private func makeSSLContext() throws -> NIOSSLContext {
        var configuration = TLSConfiguration.makeClientConfiguration()

        if let pemData {
            let bytes = Array(pemData)
            let certificates = try NIOSSLCertificate.fromPEMBytes(bytes)
            let privateKey = try NIOSSLPrivateKey(bytes: bytes, format: .pem)
            configuration.certificateChain = certificates.map { .certificate($0) }
            configuration.privateKey = .privateKey(privateKey)
        }

        return try NIOSSLContext(configuration: configuration)
    }

    // MARK: - Event handling

    private func handle(_ event: Event, from serverID: UUID) {
        let label = serverName(serverID)
        switch event {
        case .registered:
            registeredServers.insert(serverID)
            if status != .registered { status = .registered }
            append("[\(label)] Registered.")
        case .failed(let message):
            append("[\(label)] \(message)")
        case .log(let message):
            append("[\(label)] \(message)")
        }
    }

    private func serverName(_ id: UUID) -> String {
        servers.first(where: { $0.id == id })?.hostname ?? "server"
    }

    private func fail(_ message: String) {
        status = .failed(message)
        append(message)
    }

    private func append(_ message: String) {
        log.append(message)
    }

    // MARK: - Mock search results

    /// Synthesises placeholder packages so the search/results flow is testable
    /// before the real per-network bot syntax is wired up.
    private static func mockResults(
        for query: String,
        on targets: [(server: XDCCServer, channel: XDCCChannel)]
    ) -> [SearchResult] {
        let slug = query.replacingOccurrences(of: " ", with: ".")
        return targets.enumerated().flatMap { index, target in
            (1...2).map { pack in
                SearchResult(
                    fileName: "\(slug).Sample.\(index + 1)\(pack).mkv",
                    size: "\(300 + pack * 150) MB",
                    bot: "XDCCBot\(index + 1)",
                    packNumber: pack,
                    server: target.server.hostname,
                    channel: target.channel.hashName
                )
            }
        }
    }

    // MARK: - Persistence

    private func saveCustomServers() {
        let custom = servers.filter { !$0.isPredefined }
        guard let data = try? JSONEncoder().encode(custom) else { return }
        UserDefaults.standard.set(data, forKey: Self.customServersKey)
    }

    private static func loadCustomServers() -> [XDCCServer] {
        guard let data = UserDefaults.standard.data(forKey: customServersKey),
              let stored = try? JSONDecoder().decode([XDCCServer].self, from: data) else {
            return []
        }
        return stored
    }
}

// MARK: - NIO session handler

/// Sendable snapshot of the connection parameters handed to the NIO handler.
private struct SessionConfig: Sendable {
    let nick: String
    let password: String
    let host: String
    let channels: [String]
    let hasCertificate: Bool
}

/// Drives IRC registration on the event loop: sends NICK/USER, answers PING,
/// detects successful registration, identifies with NickServ and joins channels.
private final class IRCSessionHandler: ChannelInboundHandler {
    typealias InboundIn = IRCMessage

    private let config: SessionConfig
    private let onEvent: @Sendable (XDCCClient.Event) -> Void
    private var isRegistered = false

    init(config: SessionConfig, onEvent: @escaping @Sendable (XDCCClient.Event) -> Void) {
        self.config = config
        self.onEvent = onEvent
    }

    func channelActive(context: ChannelHandlerContext) {
        guard let nick = IRCNickName(config.nick) else {
            onEvent(.failed("Invalid nickname: \(config.nick)"))
            context.close(promise: nil)
            return
        }

        let userInfo = IRCUserInfo(username: config.nick,
                                   hostname: config.host,
                                   servername: config.host,
                                   realname: "SwiftXDCC User")
        send(.NICK(nick), context: context)
        send(.USER(userInfo), context: context)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)

        switch message.command {
        case .PING(let server, let server2):
            send(.PONG(server: server, server2: server2), context: context)

        case .numeric(.replyWelcome, _), .numeric(.replyEndOfMotD, _):
            if !isRegistered {
                isRegistered = true
                completeRegistration(context: context)
            }

        case .numeric(let code, let args) where !isRegistered && code.rawValue >= 400:
            onEvent(.failed("Registration error \(code.rawValue): \(args.last ?? "")"))

        case .NOTICE(_, let text):
            onEvent(.log("NOTICE: \(text)"))

        default:
            break
        }

        context.fireChannelRead(data)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onEvent(.failed("Connection error: \(error.localizedDescription)"))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        onEvent(.log("Connection closed."))
        context.fireChannelInactive()
    }

    // MARK: - Helpers

    private func completeRegistration(context: ChannelHandlerContext) {
        onEvent(.registered)

        // With a client certificate the server identifies us automatically via
        // CertFP during the TLS handshake, so no NickServ command is needed.
        // Sending one only triggers a redundant syntax-error notice.
        if config.hasCertificate {
            onEvent(.log("Using client certificate; NickServ identifies via CertFP automatically."))
        } else if let nickServ = IRCNickName("NickServ") {
            send(.PRIVMSG([.nickname(nickServ)], "IDENTIFY \(config.password)"), context: context)
            onEvent(.log("Sent NickServ IDENTIFY using password."))
        }

        joinChannels(context: context)
    }

    private func joinChannels(context: ChannelHandlerContext) {
        let names = config.channels.compactMap { IRCChannelName($0) }
        guard !names.isEmpty else { return }
        send(.JOIN(channels: names, keys: nil), context: context)
        onEvent(.log("Joining \(names.map(\.stringValue).joined(separator: ", "))."))
    }

    private func send(_ command: IRCCommand, context: ChannelHandlerContext) {
        let message = IRCMessage(command: command)
        context.writeAndFlush(NIOAny(message), promise: nil)
    }
}
