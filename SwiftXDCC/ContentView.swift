//
//  ContentView.swift
//  SwiftXDCC
//
//  Created by Marek Skrzelowski on 12/06/2026.
//

import SwiftUI

struct ContentView: View {
    @State private var client = XDCCClient()
    @State private var selection: Panel = .connection

    /// Sidebar destinations.
    private enum Panel: Hashable {
        case connection, search, console
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("XDCC") {
                    Label("Connection", systemImage: "network")
                        .tag(Panel.connection)
                    Label("Search", systemImage: "magnifyingglass")
                        .tag(Panel.search)
                        .disabled(!client.isConnected)
                    Label("Console", systemImage: "terminal")
                        .tag(Panel.console)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
            .safeAreaInset(edge: .bottom) {
                StatusFooter(client: client)
            }
        } detail: {
            switch selection {
            case .connection: ConnectionView(client: client)
            case .search: SearchView(client: client)
            case .console: ConsoleView(client: client)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .onChange(of: client.isConnected) { _, connected in
            // Search is only reachable while connected; fall back when dropping out.
            if !connected, selection == .search {
                selection = .connection
            }
        }
    }
}

/// Persistent connection status and connect/disconnect control at the bottom of
/// the sidebar.
private struct StatusFooter: View {
    let client: XDCCClient

    private var isBusy: Bool {
        client.status == .connecting || client.status == .registered
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Button(isBusy ? "Disconnect" : "Connect") {
                if isBusy { client.disconnect() } else { client.connect() }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var statusText: String {
        switch client.status {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .registered: "Connected"
        case .failed: "Failed"
        }
    }

    private var statusColor: Color {
        switch client.status {
        case .disconnected: .secondary
        case .connecting: .orange
        case .registered: .green
        case .failed: .red
        }
    }
}

#Preview {
    ContentView()
}
