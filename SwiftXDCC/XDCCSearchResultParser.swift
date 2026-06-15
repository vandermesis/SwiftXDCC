//
//  XDCCSearchResultParser.swift
//  SwiftXDCC
//
//  Created by Codex on 13/06/2026.
//

import Foundation

/// Parses private search notices containing:
/// `/msg <bot> XDCC SEND <pack>`, a dot-delimited filename, and a file size.
struct XDCCSearchResultParser {
    private static let commandExpression = try! NSRegularExpression(
        pattern: #"(?i)/msg\s+([^\s]+)\s+XDCC\s+SEND\s+#?(\d+)"#
    )
    private static let sizeExpression = try! NSRegularExpression(
        pattern: #"(?i)(\d+(?:[.,]\d+)?)\s*(TB|GB|MB|KB|T|G|M|K|B)\b"#
    )
    private static let filenameExpression = try! NSRegularExpression(
        pattern: #"(?i)(?<![/\w])([A-Z0-9][A-Z0-9._+()\[\]{}'-]*\.(?:mkv|mp4|avi|mov|wmv|m4v|webm|mpeg|mpg|ts|m2ts|vob|mp3|flac|m4a|aac|ogg|opus|wav|ape|wv|aiff|alac|tar|zip|rar|7z|gz|bz2|xz|tgz|iso|bin|cue|epub|mobi|azw3|pdf|cbz|cbr|srt|ass|ssa|nfo|txt|dmg|pkg|exe|msi|apk))(?![/\w])"#
    )
    private static let bracketedFieldExpression = try! NSRegularExpression(
        pattern: #"\[\s*([^\[\]]+?)\s*\]"#
    )

    /// Caps regex input length to bound worst-case matching on hostile input.
    /// Real search notices are far shorter than this.
    private static let maxInputLength = 4096

    static func parse(
        _ rawText: String,
        server: String
    ) -> SearchResult? {
        guard rawText.count <= maxInputLength else { return nil }
        let text = stripIRCFormatting(from: rawText)
        let fullRange = NSRange(text.startIndex..., in: text)

        guard let commandMatch = commandExpression.firstMatch(in: text, range: fullRange),
              let botRange = Range(commandMatch.range(at: 1), in: text),
              let packRange = Range(commandMatch.range(at: 2), in: text),
              let packNumber = Int(text[packRange]),
              let sizeMatch = sizeExpression.firstMatch(in: text, range: fullRange),
              let sizeValueRange = Range(sizeMatch.range(at: 1), in: text),
              let sizeUnitRange = Range(sizeMatch.range(at: 2), in: text),
              let filename = filename(
                in: text,
                server: server,
                excluding: commandMatch.range
              ) else {
            return nil
        }

        let sizeValue = String(text[sizeValueRange]).replacingOccurrences(of: ",", with: ".")
        let sizeUnit = normalizedSizeUnit(String(text[sizeUnitRange]))

        return SearchResult(
            fileName: filename,
            size: "\(sizeValue) \(sizeUnit)",
            bot: String(text[botRange]),
            packNumber: packNumber,
            server: server,
            channel: "Private notice"
        )
    }

    private static func filename(
        in text: String,
        server: String,
        excluding commandRange: NSRange
    ) -> String? {
        if server.lowercased().hasSuffix("rizon.net"),
           let filename = rizonFilename(in: text) {
            return filename
        }

        let fullRange = NSRange(text.startIndex..., in: text)
        let matches = filenameExpression.matches(in: text, range: fullRange)

        return matches.compactMap { match -> String? in
            guard NSIntersectionRange(match.range, commandRange).length == 0,
                  let range = Range(match.range(at: 1), in: text) else {
                return nil
            }

            let candidate = String(text[range]).trimmingCharacters(
                in: CharacterSet(charactersIn: "[](){}<>|,;:")
            )
            return isFilename(candidate) ? candidate : nil
        }
        .max { lhs, rhs in lhs.count < rhs.count }
    }

    private static func rizonFilename(in text: String) -> String? {
        let fullRange = NSRange(text.startIndex..., in: text)
        guard let match = bracketedFieldExpression.firstMatch(in: text, range: fullRange),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }

        let filename = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return filename.isEmpty ? nil : filename
    }

    private static func isFilename(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        guard value.count >= 5,
              value.contains("."),
              !lowercased.hasPrefix("irc."),
              !lowercased.contains("xdcc"),
              !lowercased.contains("/msg") else {
            return false
        }
        return true
    }

    private static func normalizedSizeUnit(_ value: String) -> String {
        switch value.uppercased() {
        case "T": "TB"
        case "G": "GB"
        case "M": "MB"
        case "K": "KB"
        default: value.uppercased()
        }
    }

    private static func stripIRCFormatting(from value: String) -> String {
        var result = value.replacingOccurrences(
            of: "\u{03}(?:\\d{1,2}(?:,\\d{1,2})?)?",
            with: "",
            options: .regularExpression
        )

        let controlCharacters = CharacterSet(charactersIn: "\u{02}\u{0F}\u{16}\u{1D}\u{1F}")
        result.unicodeScalars.removeAll { controlCharacters.contains($0) }
        return result
    }
}
