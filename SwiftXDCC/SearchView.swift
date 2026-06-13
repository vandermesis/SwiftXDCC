//
//  SearchView.swift
//  SwiftXDCC
//
//  Created by Marek Skrzelowski on 13/06/2026.
//

import SwiftUI

/// Lets the user search the connected servers and download found packages.
struct SearchView: View {
    let client: XDCCClient
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            results
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            TextField("Search XDCC packages…", text: $query)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit(runSearch)

            Button(action: runSearch) {
                if client.isSearching {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "magnifyingglass")
                }
            }
            .disabled(isSearchDisabled)
        }
        .padding()
    }

    @ViewBuilder
    private var results: some View {
        if client.results.isEmpty {
            ContentUnavailableView("No Results",
                                   systemImage: "tray",
                                   description: Text("Connect to the servers and search to find XDCC packages."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(client.results) { result in
                SearchResultRow(result: result) {
                    client.requestDownload(result)
                }
            }
        }
    }

    private var isSearchDisabled: Bool {
        client.isSearching || query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func runSearch() {
        client.search(query)
    }
}

/// One found package: file metadata plus a download (request) button.
private struct SearchResultRow: View {
    let result: SearchResult
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.fileName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(result.size) • \(result.bot) • \(result.channel) • \(result.server)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button(action: onDownload) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Request download")
        }
        .padding(.vertical, 2)
    }
}
