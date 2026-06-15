//
//  DCCHostPolicyTests.swift
//  SwiftXDCCTests
//

import Testing
@testable import SwiftXDCC

struct DCCHostPolicyTests {

    @Test("Blocks loopback, private, link-local and unspecified hosts", arguments: [
        "127.0.0.1",
        "127.255.255.255",
        "10.0.0.1",
        "10.255.255.255",
        "172.16.0.1",
        "172.31.255.255",
        "192.168.0.1",
        "192.168.255.255",
        "169.254.1.1",
        "0.0.0.0",
        "localhost",
        "LocalHost"
    ])
    func blocksPrivateHosts(_ host: String) {
        #expect(DCCHostPolicy.isBlocked(host))
    }

    @Test("Allows routable public hosts and near-miss ranges", arguments: [
        "8.8.8.8",
        "1.2.3.4",
        "172.15.0.1",  // just below the 172.16/12 block
        "172.32.0.1",  // just above
        "192.169.0.1", // adjacent to 192.168/16
        "169.253.0.1", // adjacent to link-local
        "203.0.113.7",
        "example.com"  // non-numeric hostname: not classifiable, allowed
    ])
    func allowsPublicHosts(_ host: String) {
        #expect(!DCCHostPolicy.isBlocked(host))
    }
}
