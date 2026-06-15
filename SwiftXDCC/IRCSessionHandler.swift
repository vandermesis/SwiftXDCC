//
//  IRCSessionHandler.swift
//  SwiftXDCC
//
//  Created by Marek Skrzelowski on 13/06/2026.
//

import Foundation
import NIO
@preconcurrency import NIOIRC

/// Repairs inbound bytes before NIOIRC parses them. NIOIRC assumes every IRC
/// argument is UTF-8 (`IRCMessageParser` throws `.invalidArgument` otherwise),
/// but real traffic — XDCC filenames, MOTD/NOTICE lines — is often Latin-1 or
/// CP1252. We frame on `\n` (never part of a multi-byte UTF-8 char, so framing
/// is lossless), keep already-valid UTF-8 lines untouched, and re-decode the
/// rest as Latin-1. ASCII is identical in both, so mostly-ASCII lines with a
/// few high bytes are recovered rather than dropped.
final class IRCByteSanitizerDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let view = buffer.readableBytesView
        guard let newline = view.firstIndex(of: UInt8(ascii: "\n")) else {
            return .needMoreData
        }
        let length = view.distance(from: view.startIndex, to: newline) + 1
        guard var line = buffer.readSlice(length: length) else {
            return .needMoreData
        }
        context.fireChannelRead(wrapInboundOut(
            Self.sanitized(&line, allocator: context.channel.allocator)
        ))
        return .continue
    }

    func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer,
                    seenEOF: Bool) throws -> DecodingState {
        guard buffer.readableBytes > 0,
              var line = buffer.readSlice(length: buffer.readableBytes) else {
            return .needMoreData
        }
        context.fireChannelRead(wrapInboundOut(
            Self.sanitized(&line, allocator: context.channel.allocator)
        ))
        return .needMoreData
    }

    private static func sanitized(_ line: inout ByteBuffer,
                                  allocator: ByteBufferAllocator) -> ByteBuffer {
        let bytes = line.readableBytesView
        // Already valid UTF-8: forward unchanged (the common case).
        if String(bytes: bytes, encoding: .utf8) != nil {
            return line
        }
        // Re-interpret each byte as a Latin-1 code point and re-encode as UTF-8.
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(bytes.count)
        for byte in bytes {
            scalars.append(Unicode.Scalar(byte))
        }
        let repaired = String(scalars)
        var out = allocator.buffer(capacity: repaired.utf8.count)
        out.writeString(repaired)
        return out
    }
}

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
           !config.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
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
