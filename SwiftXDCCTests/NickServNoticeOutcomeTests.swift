//
//  NickServNoticeOutcomeTests.swift
//  SwiftXDCCTests
//

import Testing
@testable import SwiftXDCC

struct NickServNoticeOutcomeTests {

    @Test("Recognises identify-phase success phrases", arguments: [
        "You are now identified for SwiftXDCC.",
        "Password accepted - you are now recognized.",
        "Authentication successful."
    ])
    func detectsIdentified(_ text: String) {
        #expect(NickServNoticeOutcome(text).identified)
    }

    @Test("Flags an unregistered nick without claiming success")
    func detectsNotRegistered() {
        let outcome = NickServNoticeOutcome("This nickname is not registered.")
        #expect(outcome.notRegistered)
        #expect(!outcome.identified)
        #expect(!outcome.registered)
    }

    @Test("Recognises registration success")
    func detectsRegistered() {
        #expect(NickServNoticeOutcome("Nickname SwiftXDCC is now registered.").registered)
    }

    @Test("Detects an awaited e-mail confirmation prompt")
    func detectsAwaitingConfirmation() {
        let outcome = NickServNoticeOutcome(
            "An e-mail containing the activation code has been sent to you."
        )
        #expect(outcome.awaitingConfirmation)
        #expect(!outcome.registered)
    }

    @Test("Detects a rejected confirmation code")
    func detectsCodeRejected() {
        #expect(NickServNoticeOutcome("The confirmation code is invalid.").codeRejected)
    }

    @Test("Parses the wait time from a minimum-uptime failure")
    func parsesRetriableWait() {
        let outcome = NickServNoticeOutcome("You must wait 30 seconds to register.")
        #expect(outcome.failed)
        #expect(outcome.retriableWaitSeconds == 30)
    }

    @Test("Treats a bad password as a permanent failure")
    func detectsPermanentFailure() {
        let outcome = NickServNoticeOutcome("Invalid password for SwiftXDCC.")
        #expect(outcome.failed)
        #expect(outcome.retriableWaitSeconds == nil)
    }
}
