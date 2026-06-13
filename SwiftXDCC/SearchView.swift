//
//  SearchView.swift
//  SwiftXDCC
//
//  Created by Marek Skrzelowski on 13/06/2026.
//

import SwiftUI
import UniformTypeIdentifiers

/// Searches the connected servers and lists found packages to download.
struct SearchView: View {
    let client: XDCCClient
    @State private var query = ""
    @State private var showingDirectoryPicker = false
    @State private var directoryError: String?

    var body: some View {
        VStack(spacing: 0) {
            downloadHeader
            Divider()
            content
            Spacer()
        }
        .navigationTitle("Search")
        .searchable(text: $query, placement: .toolbar, prompt: "Search packages")
        .onSubmit(of: .search) { client.search(query) }
        .fileImporter(
            isPresented: $showingDirectoryPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                try client.downloadManager.setDirectory(url)
            } catch {
                directoryError = error.localizedDescription
            }
        }
        .alert(
            "Download Folder",
            isPresented: Binding(
                get: { directoryError != nil },
                set: { if !$0 { directoryError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(directoryError ?? "")
        }
    }

    private var downloadHeader: some View {
        VStack(spacing: 10) {
            HStack {
                Label(
                    client.downloadManager.directoryURL.path(percentEncoded: false),
                    systemImage: "folder"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

                Spacer()

                Button("Downloads") {
                    client.downloadManager.useDefaultDirectory()
                }
                .help("Use the Downloads folder in your home directory")

                Button("Choose Folder…") {
                    showingDirectoryPicker = true
                }
            }

            if !client.downloadManager.items.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(client.downloadManager.items.prefix(4)) { item in
                            DownloadProgressCard(item: item)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(12)
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
            VStack(spacing: 0) {
                HStack {
                    Text("\(client.results.count) package\(client.results.count == 1 ? "" : "s")")
                        .font(.headline)
                    Spacer()
                    if client.isSearching {
                        ProgressView()
                            .controlSize(.small)
                        Text("Collecting replies…")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                List(client.results) { result in
                    SearchResultRow(result: result) {
                        client.requestDownload(result)
                    }
                }
            }
        }
    }
}

private struct DownloadProgressCard: View {
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                    .symbolEffect(.pulse, options: .repeating, isActive: isActive)

                Text(item.fileName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            ProgressView(value: item.progress)
                .progressViewStyle(.linear)
                .tint(statusColor)
                .animation(.smooth, value: item.progress)

            HStack {
                Text(item.state.label)
                    .lineLimit(1)
                Spacer()
                if item.totalBytes > 0 {
                    Text(item.progress, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: 250)
        .background(.quaternary, in: .rect(cornerRadius: 10))
    }

    private var isActive: Bool {
        item.state == .connecting || item.state == .downloading
    }

    private var statusSymbol: String {
        switch item.state {
        case .awaitingOffer: "clock"
        case .connecting: "network"
        case .downloading: "arrow.down.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch item.state {
        case .completed: .green
        case .failed: .red
        default: .accentColor
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

                HStack(spacing: 14) {
                    Label("Pack #\(result.packNumber)", systemImage: "shippingbox")
                    Label(result.size, systemImage: "internaldrive")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 14) {
                    Label(result.bot, systemImage: "person.fill")
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
