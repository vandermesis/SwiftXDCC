//
//  SearchView.swift
//  SwiftXDCC
//
//  Created by Marek Skrzelowski on 13/06/2026.
//

import SwiftUI

/// Searches the connected servers and lists found packages to download.
struct SearchView: View {
    let client: XDCCClient
    @State private var query = ""

    var body: some View {
        content
            .navigationTitle("Search")
            .searchable(text: $query, placement: .toolbar, prompt: "Search packages")
            .onSubmit(of: .search) { client.search(query) }
    }

    @ViewBuilder
    private var content: some View {
        if !client.isConnected {
            ContentUnavailableView("Not Connected",
                                   systemImage: "network.slash",
                                   description: Text("Connect to at least one server to search."))
        } else if client.isSearching && client.results.isEmpty {
            ProgressView("Searching…")
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if client.results.isEmpty {
            ContentUnavailableView("Search for Packages",
                                   systemImage: "magnifyingglass",
                                   description: Text("Type a name and press Return to search the connected servers."))
        } else {
            List(client.results) { result in
                SearchResultRow(result: result) {
                    client.requestDownload(result)
                }
            }
            .overlay(alignment: .top) {
                if client.isSearching {
                    ProgressView().controlSize(.small).padding(6)
                }
            }
        }
    }
}

/// One found package: an icon, file metadata, and a download (request) button.
private struct SearchResultRow: View {
    let result: SearchResult
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.title3)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(result.fileName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 10) {
                    Label(result.size, systemImage: "internaldrive")
                    Label(result.bot, systemImage: "person.fill")
                    Label(result.channel, systemImage: "number")
                    Label(result.server, systemImage: "server.rack")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: onDownload) {
                Label("Get", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Request download")
        }
        .padding(.vertical, 4)
    }
}
