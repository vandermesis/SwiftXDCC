//
//  XDCCClient.swift
//  SwiftXDCC
//
//  Created by Marek Skrzelowski on 12/06/2026.
//

import Foundation
import NIO
@preconcurrency import NIOIRC
@preconcurrency import NIOSSL

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
/// CertFP identities are generated or imported by ``CertFPIdentityStore`` and
/// persisted in Keychain. The client keeps password authentication enabled until
/// the current fingerprint is confirmed as registered on each network.
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
        case nickServPasswordIdentificationStarted
        /// An inbound PRIVMSG/NOTICE forwarded to the main actor.
        case incoming(kind: IncomingKind, sender: String, target: String?, text: String)
    }

    enum IncomingKind: Sendable, Equatable {
        case privmsg, notice
    }

    /// Shared IRC identity used for every connection. Editable while disconnected.
    var nick: String
    var password: String
    let port: Int

    let identityStore: CertFPIdentityStore

    /// Servers the app connects to: built-in plus any the user has added.
    /// Custom servers are persisted between launches.
    var servers: [XDCCServer] {
        didSet {
            saveCustomServers()
            saveCertCommands()
        }
    }

    /// Packages returned from the most recent search.
    private(set) var results: [SearchResult] = []
    private(set) var isSearching = false
    let downloadManager = DCCDownloadManager()

    private(set) var status: Status = .disconnected
    private(set) var log: [LogEntry] = []

    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private static let customServersKey = "customServers"
    private static let certCommandsKey = "certificateCommands"

    /// Command sent into search channels. `!s` is the common short alias.
    private static let searchCommand = "!search"
    /// How long to keep collecting streamed bot replies after issuing a search.
    private static let searchTimeout: Duration = .seconds(12)

    /// Connection events are funnelled through one ordered stream so they reach
    /// the main actor in emission order (see ``init``).
    private let eventContinuation: AsyncStream<(UUID, Event)>.Continuation

    private var channelsByServer: [UUID: any Channel] = [:]
    private var registeredServers: Set<UUID> = []
    private var pendingCertRegistrations: Set<UUID> = []
    private var certRegistrationFailures: [UUID: String] = [:]
    private var pendingNickServIdentifications: Set<UUID> = []
    private var pendingNickServRegistrations: Set<UUID> = []
    private var nickServIdentificationFailures: [UUID: String] = [:]
    private var nickServIdentified: Set<UUID> = []
    private var nickServAwaitingConfirmation: Set<UUID> = []
    private var nickServAutoRetried: Set<UUID> = []

    /// Bumped on each search/disconnect so a stale collection window can no-op.
    private var searchGeneration = 0
    /// Dedupes streamed results within the current search.
    private var seenResultKeys: Set<String> = []

    init(nick: String? = nil,
         password: String? = nil,
         pemData: Data? = nil,
         port: Port = .ssl
    ) {
        let identityStore = CertFPIdentityStore()
        self.nick = nick ?? "SwiftXDCC"
        self.password = password ?? "swiftxdcc@vandermesis.com"
        self.identityStore = identityStore
        self.port = port.rawValue
        self.servers = Self.applyingCertCommands(
            to: XDCCServer.predefined + Self.loadCustomServers()
        )

        let (stream, continuation) = AsyncStream.makeStream(of: (UUID, Event).self)
        self.eventContinuation = continuation

        if let pemData {
            try? identityStore.importPEM(pemData, displayName: "Provided identity")
        }

        // Process events strictly in order. A separate Task per event can run on
        // the main actor out of emission order, so a fast NickServ reply could be
        // handled before the flag marking us as awaiting it — dropping the notice.
        Task { [weak self] in
            for await (serverID, event) in stream {
                self?.handle(event, from: serverID)
            }
        }
    }

    var pemData: Data? { identityStore.identity?.pemData }

    /// At least one server has completed registration.
    var isConnected: Bool { !registeredServers.isEmpty }

    func isConnected(to server: XDCCServer) -> Bool {
        registeredServers.contains(server.id)
    }

    // MARK: - Connection

    /// Connects to every server in ``servers`` in parallel. Each connection
    /// registers and then joins that server's channels via their hash names.
    func connect() {
        guard channelsByServer.isEmpty else { return }

        let active = servers.filter(\.isEnabled)
        guard !active.isEmpty else {
            append("No servers selected. Enable at least one server to connect.")
            return
        }

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
        append("Connecting to \(active.count) server(s) as \(nick)…")

        for server in active {
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
                                   channels: server.connectionChannels.map(\.hashName),
                                   hasCertificate: usesCertificate,
                                   shouldIdentifyWithPassword: !usesCertificate
                                    || !identityStore.isRegistered(on: hostname))
        let continuation = eventContinuation
        let onEvent: @Sendable (Event) -> Void = { event in
            continuation.yield((serverID, event))
        }
        let port = port
        append("Connecting (TLS, port \(port))…", source: hostname)

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
        searchGeneration += 1
        isSearching = false
        for channel in channelsByServer.values {
            channel.close(mode: .all, promise: nil)
        }
        channelsByServer.removeAll()
        registeredServers.removeAll()
        pendingCertRegistrations.removeAll()
        certRegistrationFailures.removeAll()
        pendingNickServIdentifications.removeAll()
        pendingNickServRegistrations.removeAll()
        nickServIdentificationFailures.removeAll()
        nickServIdentified.removeAll()
        nickServAwaitingConfirmation.removeAll()
        nickServAutoRetried.removeAll()
        status = .disconnected
        append("Disconnected from all servers.")
    }

    // MARK: - Search

    /// Searches for `query` by sending the search command into every connected
    /// server's search-enabled channels, then collecting the bots' streamed
    /// replies (on the channel or privately) for a short window.
    func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard isConnected else {
            append("Connect to a server before searching.")
            return
        }

        // Start a fresh collection window; invalidate any in-flight one.
        searchGeneration += 1
        let generation = searchGeneration
        seenResultKeys.removeAll()
        results = []
        isSearching = true

        var sent = 0
        for server in servers where registeredServers.contains(server.id) {
            guard let channel = channelsByServer[server.id] else { continue }
            for searchChannel in server.searchChannels {
                guard let channelName = IRCChannelName(searchChannel.hashName) else { continue }
                let command = "\(Self.searchCommand) \(trimmed)"
                channel.writeAndFlush(IRCMessage(command: .PRIVMSG([.channel(channelName)], command)),
                                      promise: nil)
                append("Sent \(command) to \(searchChannel.hashName).",
                       source: server.hostname)
                sent += 1
            }
        }

        guard sent > 0 else {
            isSearching = false
            append("No search-enabled channels on the connected servers.")
            return
        }

        append("Waiting for replies from \(sent) channel(s)…")

        Task {
            try? await Task.sleep(for: Self.searchTimeout)
            guard self.searchGeneration == generation else { return }
            self.isSearching = false
            self.append("Search finished — \(self.results.count) result(s).")
        }
    }

    /// Issues the XDCC request for a result and waits for the bot's DCC offer.
    func requestDownload(_ result: SearchResult) {
        append("Requesting \(result.fileName) — xdcc send #\(result.packNumber) from \(result.bot).",
               source: result.server)

        guard let server = servers.first(where: { $0.hostname == result.server }),
              let channel = channelsByServer[server.id],
              let bot = IRCNickName(result.bot) else {
            append("Not connected; download request not sent.", source: result.server)
            return
        }

        let message = IRCMessage(command: .PRIVMSG([.nickname(bot)],
                                                   "xdcc send #\(result.packNumber)"))
        downloadManager.prepare(for: result)
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

        if let identity = identityStore.identity,
           let certificatePEM = identity.certificatePEM,
           let privateKeyPEM = identity.privateKeyPEM {
            let certificates = try NIOSSLCertificate.fromPEMBytes(
                Array(certificatePEM.utf8)
            )
            let privateKey = try NIOSSLPrivateKey(
                bytes: Array(privateKeyPEM.utf8),
                format: .pem
            )
            configuration.certificateChain = certificates.map { .certificate($0) }
            configuration.privateKey = .privateKey(privateKey)
        } else if identityStore.identity != nil {
            throw CertFPError.invalidPEM
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
            append("Registered.", source: label)
        case .failed(let message):
            append(message, source: label)
        case .log(let message):
            append(message, source: label)
        case .nickServPasswordIdentificationStarted:
            pendingNickServIdentifications.insert(serverID)
            nickServIdentificationFailures[serverID] = nil
            nickServIdentified.remove(serverID)
            nickServAwaitingConfirmation.remove(serverID)
            nickServAutoRetried.remove(serverID)
        case .incoming(kind: let kind, sender: let sender, target: let target, text: let text):
            let destination = target ?? "private"
            if sender.caseInsensitiveCompare("NickServ") == .orderedSame,
               handleNickServPasswordNotice(text, serverID: serverID) {
                append("[NOTICE private] <\(sender)> \(text)", source: label)
                return
            }
            if sender.caseInsensitiveCompare("NickServ") == .orderedSame,
               handleNickServCertificateNotice(text, serverID: serverID) {
                append("[NOTICE private] <\(sender)> \(text)", source: label)
                return
            }
            if kind == .privmsg,
               let offer = DCCOfferParser.parse(text, bot: sender, server: label) {
                append("Accepted DCC offer for \(offer.fileName) from \(sender).", source: label)
                downloadManager.accept(offer)
                return
            }
            if kind == .notice,
               target?.hasPrefix("#") != true,
               handlePackageNotice(text, server: label) {
                return
            }
            if shouldSuppressChannelMessage(target: target, serverID: serverID) {
                return
            }
            append("[\(kind.label) \(destination)] <\(sender)> \(text)", source: label)
        }
    }

    /// Returns true when a private notice has the complete search-result format.
    private func handlePackageNotice(
        _ text: String,
        server: String
    ) -> Bool {
        guard let result = XDCCSearchResultParser.parse(
            text,
            server: server
        ) else {
            return false
        }

        guard isSearching else { return false }

        let key = "\(server.lowercased())|\(result.bot.lowercased())|\(result.packNumber)"
        guard seenResultKeys.insert(key).inserted else { return true }

        results.append(result)
        results.sort {
            if $0.fileName.localizedStandardCompare($1.fileName) == .orderedSame {
                return $0.packNumber < $1.packNumber
            }
            return $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
        }
        return true
    }

    private func serverName(_ id: UUID) -> String {
        servers.first(where: { $0.id == id })?.hostname ?? "server"
    }

    private func shouldSuppressChannelMessage(target: String?, serverID: UUID) -> Bool {
        guard let target,
              target.hasPrefix("#"),
              let server = servers.first(where: { $0.id == serverID }),
              let channel = server.channels.first(where: {
                  $0.hashName.caseInsensitiveCompare(target) == .orderedSame
              }) else {
            return false
        }
        return channel.type.contains(.download)
    }

    private func fail(_ message: String) {
        status = .failed(message)
        append(message)
    }

    private func append(_ message: String, source: String? = nil) {
        log.append(.init(message: message, source: source))
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

// MARK: - NickServ & CertFP authentication

extension XDCCClient {
    func certFPState(for server: XDCCServer) -> CertFPRegistrationState {
        if pendingCertRegistrations.contains(server.id) {
            return .registering
        }
        if let failure = certRegistrationFailures[server.id] {
            return .failed(failure)
        }
        return identityStore.registrationState(for: server.hostname)
    }

    func registerCertificate(on server: XDCCServer) {
        guard identityStore.identity != nil else {
            append("Generate or import a certificate first.", source: server.hostname)
            return
        }
        guard registeredServers.contains(server.id),
              let channel = channelsByServer[server.id],
              let nickServ = IRCNickName("NickServ") else {
            append("Connect to this server before registering CertFP.", source: server.hostname)
            return
        }

        pendingCertRegistrations.insert(server.id)
        certRegistrationFailures[server.id] = nil
        let command = certificateCommand(for: server)
        channel.writeAndFlush(
            IRCMessage(command: .PRIVMSG([.nickname(nickServ)], command)),
            promise: nil
        )
        append("Sent NickServ \(command).", source: server.hostname)
    }

    func forgetCertificateRegistration(on server: XDCCServer) {
        pendingCertRegistrations.remove(server.id)
        certRegistrationFailures[server.id] = nil
        identityStore.markUnregistered(on: server.hostname)
    }

    /// Once NickServ accepts the password, the session is authenticated, so we
    /// can add the CertFP fingerprint right away — making future connections
    /// passwordless. No-op without a certificate or once it's already registered.
    private func autoRegisterCertificateIfNeeded(serverID: UUID) {
        guard identityStore.identity != nil,
              let server = servers.first(where: { $0.id == serverID }),
              !identityStore.isRegistered(on: server.hostname),
              !pendingCertRegistrations.contains(serverID) else {
            return
        }
        append("NickServ authentication succeeded; registering CertFP automatically.",
               source: server.hostname)
        registerCertificate(on: server)
    }

    func nickServState(for server: XDCCServer) -> NickServAuthState {
        let id = server.id
        if pendingNickServIdentifications.contains(id)
            || pendingNickServRegistrations.contains(id) {
            return .checking
        }
        if let failure = nickServIdentificationFailures[id] {
            return .failed(failure)
        }
        if nickServAwaitingConfirmation.contains(id) {
            return .awaitingConfirmation
        }
        if nickServIdentified.contains(id) {
            return .identified
        }
        if identityStore.identity != nil,
           identityStore.isRegistered(on: server.hostname) {
            return .unavailable("CertFP registered, password fallback disabled")
        }
        return .needsRegistration("Identify with NickServ password, or Register the nickname")
    }

    /// Retries NickServ registration after a failure, mirroring CertFP's manual
    /// Register button. Sends `REGISTER` again with the current password.
    func registerNickServ(on server: XDCCServer) {
        guard registeredServers.contains(server.id) else {
            append("Connect to this server before registering with NickServ.",
                   source: server.hostname)
            return
        }
        nickServIdentificationFailures[server.id] = nil
        sendNickServRegister(serverID: server.id)
    }

    /// Completes a registration that requires e-mail verification by sending the
    /// code the user received to NickServ (`CONFIRM <code>`).
    func confirmNickServRegistration(on server: XDCCServer, code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard registeredServers.contains(server.id),
              let channel = channelsByServer[server.id],
              let nickServ = IRCNickName("NickServ") else {
            append("Connect to this server before confirming registration.", source: server.hostname)
            return
        }

        nickServAwaitingConfirmation.remove(server.id)
        nickServIdentificationFailures[server.id] = nil
        // Reuse the registration-pending phase so the CONFIRM reply is handled.
        pendingNickServRegistrations.insert(server.id)
        channel.writeAndFlush(
            IRCMessage(command: .PRIVMSG([.nickname(nickServ)], "CONFIRM \(trimmed)")),
            promise: nil
        )
        append("Sent NickServ CONFIRM.", source: server.hostname)
    }

    fileprivate func handleNickServCertificateNotice(_ text: String, serverID: UUID) -> Bool {
        guard pendingCertRegistrations.contains(serverID),
              let server = servers.first(where: { $0.id == serverID }) else {
            return false
        }

        let lower = text.lowercased()
        // Rizon's reply is "<fingerprint hex> added to your access list" — the
        // raw hex contains none of the cert keywords, so "access list" matters.
        let mentionsCertificate = lower.contains("cert")
            || lower.contains("fingerprint")
            || lower.contains("ssl")
            || lower.contains("access list")
        let succeeded = lower.contains("added")
            || lower.contains("already")
            || lower.contains("success")
        let failed = lower.contains("error")
            || lower.contains("invalid")
            || lower.contains("not identified")
            || lower.contains("denied")
            || lower.contains("unknown command")

        if mentionsCertificate && succeeded {
            pendingCertRegistrations.remove(serverID)
            certRegistrationFailures[serverID] = nil
            identityStore.markRegistered(on: server.hostname)
            append("CertFP registration confirmed.", source: server.hostname)
            return true
        }
        if failed {
            pendingCertRegistrations.remove(serverID)
            certRegistrationFailures[serverID] = text
            append("CertFP registration failed: \(text)", source: server.hostname)
            return true
        }
        return false
    }

    fileprivate func handleNickServPasswordNotice(_ text: String, serverID: UUID) -> Bool {
        let identifying = pendingNickServIdentifications.contains(serverID)
        let registering = pendingNickServRegistrations.contains(serverID)
        guard identifying || registering else { return false }

        let outcome = NickServNoticeOutcome(text)

        // Email confirmation wins over a generic "registered" success, since a
        // registration awaiting an emailed code isn't usable yet. The prompt can
        // arrive in either phase (IDENTIFY to an unconfirmed nick, or after
        // REGISTER), so it isn't gated on `registering`.
        if outcome.awaitingConfirmation {
            pendingNickServIdentifications.remove(serverID)
            pendingNickServRegistrations.remove(serverID)
            nickServIdentificationFailures[serverID] = nil
            nickServAwaitingConfirmation.insert(serverID)
            append("NickServ requires an e-mail verification code. Enter the code you received and tap Register.",
                   source: serverName(serverID))
            return true
        }

        if outcome.identified || (registering && outcome.registered) {
            markNickServAuthenticated(serverID: serverID)
            return true
        }

        // Only auto-register from the IDENTIFY phase, so a failed registration
        // doesn't loop back into another REGISTER.
        if identifying, outcome.notRegistered {
            pendingNickServIdentifications.remove(serverID)
            nickServIdentificationFailures[serverID] = nil
            append("NickServ reported this nickname is not registered; sending REGISTER.",
                   source: serverName(serverID))
            sendNickServRegister(serverID: serverID)
            return true
        }

        if registering, outcome.codeRejected {
            pendingNickServIdentifications.remove(serverID)
            pendingNickServRegistrations.remove(serverID)
            nickServIdentificationFailures[serverID] = nil
            nickServAwaitingConfirmation.insert(serverID)
            append("NickServ rejected the verification code: \(text)", source: serverName(serverID))
            return true
        }

        if outcome.failed {
            if registering,
               let wait = outcome.retriableWaitSeconds,
               !nickServAutoRetried.contains(serverID),
               registeredServers.contains(serverID) {
                scheduleNickServRegisterRetry(serverID: serverID, after: wait)
                return true
            }
            pendingNickServIdentifications.remove(serverID)
            pendingNickServRegistrations.remove(serverID)
            nickServIdentificationFailures[serverID] = text
            let phase = registering ? "registration" : "authentication"
            append("NickServ \(phase) failed: \(text)", source: serverName(serverID))
            return true
        }

        return false
    }

    /// Defers one automatic REGISTER retry past a network's minimum-uptime rule
    /// (e.g. "you must wait 30 seconds to register"). Falls back to the manual
    /// Register button if the retry also fails.
    private func scheduleNickServRegisterRetry(serverID: UUID, after seconds: Int) {
        nickServAutoRetried.insert(serverID)
        // Keep the row showing progress (not a failure) while we wait.
        pendingNickServRegistrations.insert(serverID)
        nickServIdentificationFailures[serverID] = nil
        let wait = seconds + 5  // small buffer past the network's minimum
        append("NickServ registration deferred by the network; retrying in \(wait)s.",
               source: serverName(serverID))
        Task {
            try? await Task.sleep(for: .seconds(wait))
            guard registeredServers.contains(serverID),
                  channelsByServer[serverID] != nil else { return }
            append("Retrying NickServ REGISTER.", source: serverName(serverID))
            sendNickServRegister(serverID: serverID)
        }
    }

    /// Marks NickServ password authentication as confirmed and chains into
    /// automatic CertFP registration so future connections can be passwordless.
    private func markNickServAuthenticated(serverID: UUID) {
        pendingNickServIdentifications.remove(serverID)
        pendingNickServRegistrations.remove(serverID)
        nickServAwaitingConfirmation.remove(serverID)
        nickServIdentificationFailures[serverID] = nil
        nickServIdentified.insert(serverID)
        append("NickServ password authentication confirmed.", source: serverName(serverID))
        autoRegisterCertificateIfNeeded(serverID: serverID)
    }

    private func sendNickServRegister(serverID: UUID) {
        guard let channel = channelsByServer[serverID],
              let nickServ = IRCNickName("NickServ") else {
            return
        }

        pendingNickServRegistrations.insert(serverID)
        nickServIdentified.remove(serverID)
        nickServAwaitingConfirmation.remove(serverID)
        let command = "REGISTER \(password) swiftxdcc@vandermesis.com"
        channel.writeAndFlush(
            IRCMessage(command: .PRIVMSG([.nickname(nickServ)], command)),
            promise: nil
        )
        append("Sent NickServ REGISTER.", source: serverName(serverID))
    }
}

// MARK: - Per-server certificate command

extension XDCCClient {
    /// The CertFP registration command for a server, with `%fp` replaced by the
    /// fingerprint (lowercase, no separators — the form services expect).
    func certificateCommand(for server: XDCCServer) -> String {
        let trimmed = server.certificateCommand.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty ? "CERT ADD" : trimmed
        guard let fingerprint = identityStore.identity?.fingerprint else { return base }
        let plain = fingerprint.replacingOccurrences(of: ":", with: "").lowercased()
        return base.replacingOccurrences(of: "%fp", with: plain, options: .caseInsensitive)
    }

    /// Persists non-default per-host command overrides. Predefined servers aren't
    /// otherwise saved, so this is what makes an edit (e.g. Rizon) stick.
    func saveCertCommands() {
        let overrides = servers.reduce(into: [String: String]()) { result, server in
            let command = server.certificateCommand.trimmingCharacters(in: .whitespaces)
            if !command.isEmpty, command != "CERT ADD" {
                result[server.hostname.lowercased()] = command
            }
        }
        UserDefaults.standard.set(overrides, forKey: Self.certCommandsKey)
    }

    static func applyingCertCommands(to servers: [XDCCServer]) -> [XDCCServer] {
        let overrides = UserDefaults.standard
            .dictionary(forKey: certCommandsKey) as? [String: String] ?? [:]
        guard !overrides.isEmpty else { return servers }
        return servers.map { server in
            guard let command = overrides[server.hostname.lowercased()] else { return server }
            var copy = server
            copy.certificateCommand = command
            return copy
        }
    }
}

// MARK: - Incoming message kind

private extension XDCCClient.IncomingKind {
    var label: String {
        switch self {
        case .privmsg: "PRIVMSG"
        case .notice: "NOTICE"
        }
    }
}
