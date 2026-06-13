//
//  ConsoleView.swift
//  SwiftXDCC
//
//  Created by Marek Skrzelowski on 13/06/2026.
//

import SwiftUI

/// Scrolling activity log mirroring everything the client reports.
struct ConsoleView: View {
    let client: XDCCClient

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(client.log.enumerated()), id: \.offset) { index, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let source = entry.source {
                                Text(source)
                                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(color(for: source))
                                    .frame(width: 150, alignment: .leading)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Text(entry.message)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(entry.source.map(color(for:)) ?? .primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(index)
                    }
                }
                .padding(12)
            }
            .onChange(of: client.log.count) { _, count in
                guard count > 0 else { return }
                withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
        .overlay {
            if client.log.isEmpty {
                ContentUnavailableView("No Activity",
                                       systemImage: "terminal",
                                       description: Text("Connection and search activity appears here."))
            }
        }
        .navigationTitle("Console")
        .toolbar {
            Button("Clear", systemImage: "trash") {
                client.clearLog()
            }
            .disabled(client.log.isEmpty)
        }
    }

    private func color(for source: String) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .red]
        if let index = client.servers.firstIndex(where: {
            $0.hostname.caseInsensitiveCompare(source) == .orderedSame
        }) {
            if index < palette.count {
                return palette[index]
            }

            let hue = (Double(index) * 0.618_033_988_75)
                .truncatingRemainder(dividingBy: 1)
            return Color(hue: hue, saturation: 0.78, brightness: 0.88)
        }
        return .secondary
    }
}
