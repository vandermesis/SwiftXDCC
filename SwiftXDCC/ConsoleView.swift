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
                        Text(entry)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
}
