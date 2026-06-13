//
//  NickServAuth.swift
//  SwiftXDCC
//
//  Created by Marek Skrzelowski on 13/06/2026.
//

import Foundation

/// Status of NickServ password authentication for a single server, used to drive
/// the Connection screen. `.failed` offers a manual REGISTER retry, mirroring CertFP.
enum NickServAuthState: Equatable {
    case checking
    case identified
    case awaitingConfirmation
    case failed(String)
    case needsRegistration(String)
    case unavailable(String)

    var label: String {
        switch self {
        case .checking: "Checking NickServ password authentication…"
        case .identified: "Identified with NickServ password"
        case .awaitingConfirmation: "This nick is awaiting an e-mail verification code before completing registration."
        case .failed(let message): message
        case .needsRegistration(let message): message
        case .unavailable(let message): message
        }
    }
}

/// Classifies a NickServ NOTICE while identifying or registering. Wording varies
/// by IRCd (Atheme/Anope/…), so each outcome matches a broad set of phrases.
struct NickServNoticeOutcome {
    /// Identify-phase success ("you are now identified", …).
    let identified: Bool
    /// Register-phase success. The broad `registered` match is only trusted by
    /// the caller while registering, so the connect-time "registered and
    /// protected" warning isn't mistaken for success.
    let registered: Bool
    let notRegistered: Bool
    let awaitingConfirmation: Bool
    let failed: Bool
    /// The network rejected the emailed CONFIRM code; the caller re-arms the
    /// awaiting state so the user can re-enter it.
    let codeRejected: Bool
    /// When the failure is a "you must wait N seconds" rule, the parsed N so the
    /// caller can defer one automatic retry. Nil for permanent failures.
    let retriableWaitSeconds: Int?

    init(_ text: String) {
        let lower = text.lowercased()
        notRegistered = lower.contains("not registered")
            || lower.contains("isn't registered")
            || lower.contains("is not a registered")
        identified = lower.contains("you are now identified")
            || lower.contains("password accepted")
            || lower.contains("identified for")
            || lower.contains("authentication successful")
        // "Nickname X registered.", "is now registered", and the CONFIRM-code
        // success replies ("…has been confirmed/activated/verified").
        registered = lower.contains("is now registered")
            || lower.contains("registration successful")
            || lower.contains("successfully registered")
            || lower.contains("has been confirmed")
            || lower.contains("has been activated")
            || lower.contains("has been verified")
            || lower.contains("verification successful")
            || (lower.contains("registered")
                && !notRegistered
                && !lower.contains("to register"))
        // Registration accepted but the network requires an emailed confirmation
        // code first. "e-mail"/"email" spellings both occur (Rizon uses the
        // hyphen). The "awaiting …" prompt is matched directly; the "…has been
        // sent" form excludes "confirmed"/"verified" so a later success reply
        // isn't re-read as a fresh request.
        let mentionsEmail = lower.contains("email") || lower.contains("e-mail")
        let awaitingPrompt = lower.contains("awaiting")
            && (lower.contains("verification") || lower.contains("confirmation")
                || mentionsEmail)
        awaitingConfirmation = lower.contains("passcode")
            || lower.contains("/msg nickserv confirm")
            || awaitingPrompt
            || (mentionsEmail
                && (lower.contains("sent") || lower.contains("activation"))
                && !lower.contains("confirmed")
                && !lower.contains("verified"))
        codeRejected = (lower.contains("code") || lower.contains("verification")
                || lower.contains("passcode"))
            && (lower.contains("invalid") || lower.contains("incorrect")
                || lower.contains("expired") || lower.contains("wrong")
                || lower.contains("does not match") || lower.contains("denied"))
        let waitFailure = lower.contains("seconds to register")
            || lower.contains("must have been using")
            || lower.contains("you must wait")
        failed = lower.contains("invalid password")
            || lower.contains("password incorrect")
            || lower.contains("registration failed")
            || lower.contains("access denied")
            || waitFailure
        if waitFailure {
            let parsed = lower.split(whereSeparator: { !$0.isNumber })
                .compactMap { Int($0) }
                .first
            retriableWaitSeconds = parsed ?? 30
        } else {
            retriableWaitSeconds = nil
        }
    }
}
