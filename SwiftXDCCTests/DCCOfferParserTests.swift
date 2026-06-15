//
//  DCCOfferParserTests.swift
//  SwiftXDCCTests
//

import Testing
@testable import SwiftXDCC

struct DCCOfferParserTests {

    @Test("Parses a plain DCC SEND with an integer host")
    func parsesIntegerHost() throws {
        // 3232235777 == 0xC0A80101 == 192.168.1.1
        let offer = try #require(
            DCCOfferParser.parse(
                "DCC SEND file.mkv 3232235777 5000 12345",
                bot: "Bot",
                server: "irc.example.net"
            )
        )
        #expect(offer.fileName == "file.mkv")
        #expect(offer.host == "192.168.1.1")
        #expect(offer.port == 5000)
        #expect(offer.byteCount == 12345)
        #expect(offer.bot == "Bot")
        #expect(offer.server == "irc.example.net")
    }

    @Test("Parses a quoted filename containing spaces and a dotted host")
    func parsesQuotedNameAndDottedHost() throws {
        let offer = try #require(
            DCCOfferParser.parse(
                #"DCC SEND "my movie.mkv" 127.0.0.1 6000 999"#,
                bot: "Bot",
                server: "s"
            )
        )
        #expect(offer.fileName == "my movie.mkv")
        #expect(offer.host == "127.0.0.1")
        #expect(offer.port == 6000)
        #expect(offer.byteCount == 999)
    }

    @Test("Strips CTCP \\u{01} wrappers before matching")
    func parsesCTCPWrapped() throws {
        // 2130706433 == 0x7F000001 == 127.0.0.1
        let offer = try #require(
            DCCOfferParser.parse(
                "\u{01}DCC SEND data.bin 2130706433 1234 1\u{01}",
                bot: "Bot",
                server: "s"
            )
        )
        #expect(offer.fileName == "data.bin")
        #expect(offer.host == "127.0.0.1")
    }

    @Test("Reduces a path in the filename to its last component")
    func stripsPathFromFilename() throws {
        let offer = try #require(
            DCCOfferParser.parse(
                "DCC SEND /etc/passwd 1.2.3.4 22 5",
                bot: "Bot",
                server: "s"
            )
        )
        #expect(offer.fileName == "passwd")
    }

    @Test("Rejects non-offers and out-of-range ports", arguments: [
        "hello there",
        "DCC CHAT chat 1.2.3.4 5000 0",
        "DCC SEND file 1.2.3.4 99999 5", // port > UInt16.max
        "DCC SEND file notanumber 5000 5"
    ])
    func rejectsInvalid(_ text: String) {
        #expect(DCCOfferParser.parse(text, bot: "Bot", server: "s") == nil)
    }
}
