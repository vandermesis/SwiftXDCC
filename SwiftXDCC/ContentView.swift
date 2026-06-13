//
//  ContentView.swift
//  SwiftXDCC
//
//  Created by Marek Skrzelowski on 12/06/2026.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var client = XDCCClient()
    @State private var showingImporter = false
    @State private var pemFileName: String?

    private var isBusy: Bool {
        client.status == .connecting || client.status == .registered
    }

    var body: some View {
        TabView {
            connectionTab
                .tabItem { Label("Connection", systemImage: "network") }

            SearchView(client: client)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }

            ConsoleView(client: client)
                .tabItem { Label("Console", systemImage: "terminal") }
        }
        .frame(minWidth: 520, minHeight: 640)
    }

    // MARK: - Connection tab

    private var connectionTab: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    identityForm
                    actionButtons
                    serversLink
                }
                .padding(24)
            }
            .fileImporter(isPresented: $showingImporter,
                          allowedContentTypes: [UTType(filenameExtension: "pem") ?? .data],
                          allowsMultipleSelection: false) { result in
                importCertificate(result)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.largeTitle)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("SwiftXDCC")
                    .font(.title2.bold())
                Text("IRC over TLS")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            statusBadge
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(statusColor.opacity(0.15), in: Capsule())
        .foregroundStyle(statusColor)
    }

    // MARK: - Identity form

    private var identityForm: some View {
        GroupBox {
            VStack(spacing: 12) {
                row("Nickname", systemImage: "person.fill") {
                    TextField("SwiftXDCC", text: Binding(get: { client.nick },
                                                         set: { client.nick = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }

                row("Password", systemImage: "key.fill") {
                    SecureField("NickServ password", text: Binding(get: { client.password },
                                                                   set: { client.password = $0 }))
                        .textFieldStyle(.roundedBorder)
                }

                row("Certificate", systemImage: "lock.doc.fill") {
                    HStack(spacing: 8) {
                        Text(pemFileName ?? "None — password auth")
                            .font(.callout)
                            .foregroundStyle(pemFileName == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if pemFileName != nil {
                            Button("Clear") {
                                client.pemData = nil
                                pemFileName = nil
                                client.note("Certificate cleared; using password auth.")
                            }
                            .buttonStyle(.borderless)
                        }
                        Button("Choose…") { showingImporter = true }
                    }
                }
            }
            .padding(4)
        } label: {
            Label("Identity", systemImage: "person.crop.circle")
                .font(.headline)
        }
        .disabled(isBusy)
    }

    private func row(_ title: String,
                     systemImage: String,
                     @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            content()
        }
    }

    // MARK: - Servers

    private var serversLink: some View {
        NavigationLink {
            ServerManagerView(client: client)
        } label: {
            HStack {
                Label("Manage servers", systemImage: "server.rack")
                Spacer()
                Text("\(client.servers.count)")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    // MARK: - Actions

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                client.connect()
            } label: {
                Label("Connect All", systemImage: "bolt.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy)

            Button {
                client.disconnect()
            } label: {
                Label("Disconnect", systemImage: "xmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(client.status == .disconnected)
        }
        .controlSize(.large)
    }

    // MARK: - Status presentation

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

    // MARK: - Certificate import

    /// Reads the user-selected PEM while holding security-scoped access, since
    /// the sandbox only grants access to files the user explicitly picks.
    private func importCertificate(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            guard url.startAccessingSecurityScopedResource() else {
                client.note("Couldn't access the selected certificate.")
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                client.pemData = try Data(contentsOf: url)
                pemFileName = url.lastPathComponent
                client.note("Selected certificate: \(url.lastPathComponent)")
            } catch {
                client.note("Failed to read certificate: \(error.localizedDescription)")
            }

        case .failure(let error):
            client.note("Certificate import failed: \(error.localizedDescription)")
        }
    }
}

#Preview {
    ContentView()
}
