//
//  XDCCClient.swift
//  SwiftXDCC
//
//  Created by Marek Skrzelowski on 12/06/2026.
//

import Foundation
import NIO
import NIOIRC
import NIOSSL

struct XDCCChannel: Identifiable, Hashable {
    let id: UUID = UUID()
    let name: String
    let type: [XDCCChannelType]
    
    var hashName: String {
        return "#\(name)"
    }
}

enum XDCCChannelType: String, CaseIterable {
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

/// Service that connects to an IRC server over TLS and registers the nick with
/// NickServ.
///
/// All connection parameters are optional. When a value is not supplied the
/// service falls back to a sensible default:
/// - `host`: the first ``XDCCHost`` (`irc.abjects.net`)
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

    /// Events forwarded from the NIO event loop back to the main actor.
    enum Event: Sendable {
        case registered
        case failed(String)
        case log(String)
    }

    /// Resolved connection parameters. Editable from the UI while disconnected.
    var host: String
    var nick: String
    var password: String
    let port: Int

    /// PEM bytes (certificate + private key) for CertFP. Set from a
    /// user-selected file before calling ``connect()``.
    var pemData: Data?

    private(set) var status: Status = .disconnected
    private(set) var log: [String] = []

    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: (any Channel)?

    init(host: String? = nil,
         nick: String? = nil,
         password: String? = nil,
         pemData: Data? = nil,
         port: Port = .ssl
    ) {
        self.host = host ?? XDCCHost.abjects.name
        self.nick = nick ?? "SwiftXDCC"
        self.password = password ?? "swiftxdcc@vandermesis.com"
        self.pemData = pemData
        self.port = port.rawValue
    }

    // MARK: - Connection

    func connect() {
        guard channel == nil else { return }

        let sslContext: NIOSSLContext
        do {
            sslContext = try makeSSLContext()
        } catch {
            fail("TLS setup failed: \(error.localizedDescription)")
            return
        }

        let usesCertificate = pemData != nil
        status = .connecting
        append("Connecting to \(host):\(port) (TLS) as \(nick)…")

        let config = SessionConfig(nick: nick,
                                   password: password,
                                   host: host,
                                   hasCertificate: usesCertificate)
        let serverHostname = host
        let onEvent: @Sendable (Event) -> Void = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        let host = host
        let port = port

        Task {
            let bootstrap = ClientBootstrap(group: Self.group)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { channel in
                    do {
                        let tls = try NIOSSLClientHandler(context: sslContext,
                                                          serverHostname: serverHostname)
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
                let channel = try await bootstrap.connect(host: host, port: port).get()
                self.channel = channel
            } catch {
                self.fail("Connection failed: \(error.localizedDescription)")
            }
        }
    }

    func disconnect() {
        channel?.close(mode: .all, promise: nil)
        channel = nil
        status = .disconnected
        append("Disconnected.")
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

    private func handle(_ event: Event) {
        switch event {
        case .registered:
            status = .registered
            append("Registered as \(nick).")
        case .failed(let message):
            status = .failed(message)
            append(message)
        case .log(let message):
            append(message)
        }
    }

    private func fail(_ message: String) {
        status = .failed(message)
        append(message)
    }

    private func append(_ message: String) {
        log.append(message)
    }
}

// MARK: - NIO session handler

/// Sendable snapshot of the connection parameters handed to the NIO handler.
private struct SessionConfig: Sendable {
    let nick: String
    let password: String
    let host: String
    let hasCertificate: Bool
}

/// Drives IRC registration on the event loop: sends NICK/USER, answers PING,
/// detects successful registration and identifies with NickServ.
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
            return
        }

        guard let nickServ = IRCNickName("NickServ") else { return }
        send(.PRIVMSG([.nickname(nickServ)], "IDENTIFY \(config.password)"), context: context)
        onEvent(.log("Sent NickServ IDENTIFY using password."))
    }

    private func send(_ command: IRCCommand, context: ChannelHandlerContext) {
        let message = IRCMessage(command: command)
        context.writeAndFlush(NIOAny(message), promise: nil)
    }
}
