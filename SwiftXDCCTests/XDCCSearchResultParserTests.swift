//
//  XDCCSearchResultParserTests.swift
//  SwiftXDCCTests
//

import Testing
@testable import SwiftXDCC

struct XDCCSearchResultParserTests {

    @Test("Parses bot, pack, filename and size from a standard notice")
    func parsesStandardNotice() throws {
        let result = try #require(
            XDCCSearchResultParser.parse(
                "/msg CoolBot XDCC SEND #5 Some.Movie.mkv [350M]",
                server: "irc.abjects.net"
            )
        )
        #expect(result.bot == "CoolBot")
        #expect(result.packNumber == 5)
        #expect(result.fileName == "Some.Movie.mkv")
        #expect(result.size == "350 MB")
        #expect(result.server == "irc.abjects.net")
    }

    @Test("Normalises single-letter size units to two-letter form", arguments: [
        ("[350M]", "350 MB"),
        ("[1.4G]", "1.4 GB"),
        ("[700 MB]", "700 MB"),
        ("[2T]", "2 TB")
    ])
    func normalisesSizeUnits(_ token: String, _ expected: String) throws {
        let result = try #require(
            XDCCSearchResultParser.parse(
                "/msg Bot XDCC SEND #1 Clip.mkv \(token)",
                server: "irc.abjects.net"
            )
        )
        #expect(result.size == expected)
    }

    @Test("Uses the bracketed field as the filename on Rizon")
    func usesBracketedFilenameOnRizon() throws {
        let result = try #require(
            XDCCSearchResultParser.parse(
                "/msg RizonBot XDCC SEND #7 [The.Movie.2021.mkv] 700MB",
                server: "irc.rizon.net"
            )
        )
        #expect(result.fileName == "The.Movie.2021.mkv")
        #expect(result.bot == "RizonBot")
        #expect(result.packNumber == 7)
        #expect(result.size == "700 MB")
    }

    @Test("Returns nil when the notice is not a search result", arguments: [
        "just some chatter in the channel",
        "/msg Bot XDCC SEND #5 no-recognised-extension-here",
        "Some.Movie.mkv [350M] but no command"
    ])
    func rejectsNonResults(_ text: String) {
        #expect(XDCCSearchResultParser.parse(text, server: "irc.abjects.net") == nil)
    }

    @Test("Rejects over-long input before running the regex")
    func rejectsOversizedInput() {
        let padded = "/msg Bot XDCC SEND #1 Clip.mkv [350M] "
            + String(repeating: "x", count: 4100)
        #expect(XDCCSearchResultParser.parse(padded, server: "irc.abjects.net") == nil)
    }
}
