//
//  IRCSessionHandler.swift
//  SwiftXDCC
//
//  Created by Marek Skrzelowski on 13/06/2026.
//

import Foundation
import NIO
@preconcurrency import NIOIRC

/// Sendable snapshot of the connection parameters handed to the NIO handler.
struct SessionConfig: Sendable {
    let nick: String
    let password: String
    let host: String
    let channels: [String]
    let hasCertificate: Bool
    let shouldIdentifyWithPassword: Bool
}

/// Drives IRC registration on the event loop: sends NICK/USER, answers PING,
/// detects successful registration, identifies with NickServ and joins channels.
final class IRCSessionHandler: ChannelInboundHandler {
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
                                   realname: "SwiftXDCC")
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

        case .PRIVMSG(let recipients, let text):
            onEvent(.incoming(
                kind: .privmsg,
                sender: sender(from: message.origin),
                target: recipients.first?.stringValue ?? message.target,
                text: text
            ))

        case .NOTICE(let recipients, let text):
            onEvent(.incoming(
                kind: .notice,
                sender: sender(from: message.origin),
                target: recipients.first?.stringValue ?? message.target,
                text: text
            ))

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

        if config.hasCertificate {
            onEvent(.log("Presented the CertFP client certificate during TLS."))
        }

        if config.shouldIdentifyWithPassword,
           let nickServ = IRCNickName("NickServ") {
            onEvent(.nickServPasswordIdentificationStarted)
            onEvent(.log("NickServ password fallback is active because the current fingerprint is not registered yet."))
            send(.PRIVMSG([.nickname(nickServ)], "IDENTIFY \(config.password)"), context: context)
            onEvent(.log("Sent NickServ IDENTIFY while CertFP registration is unconfirmed."))
        } else if config.hasCertificate {
            onEvent(.log("Using confirmed CertFP authentication; password IDENTIFY skipped."))
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

    private func sender(from origin: String?) -> String {
        guard let origin, !origin.isEmpty else { return "server" }
        return origin.split(separator: "!", maxSplits: 1).first.map(String.init) ?? origin
    }
}
