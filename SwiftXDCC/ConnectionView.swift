//
//  ConnectionView.swift
//  SwiftXDCC
//
//  Created by Marek Skrzelowski on 13/06/2026.
//

import SwiftUI
import UniformTypeIdentifiers

/// Connection settings: shared IRC identity plus the selectable list of servers.
struct ConnectionView: View {
    @Bindable var client: XDCCClient

    @State private var showingImporter = false
    @State private var showingAddServer = false
    @State private var pemFileName: String?

    private var isBusy: Bool {
        client.status == .connecting || client.status == .registered
    }

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Nickname", text: $client.nick)
                    .autocorrectionDisabled()
                SecureField("NickServ Password", text: $client.password)
                certificateRow
            }

            Section {
                ForEach($client.servers) { $server in
                    ServerRow(server: $server) {
                        client.servers.removeAll { $0.id == server.id }
                    }
                }
            } header: {
                HStack {
                    Text("Servers")
                    Spacer()
                    Button {
                        showingAddServer = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add a custom server")
                }
            } footer: {
                Text("Switch on the servers to connect to. Search runs on channels tagged “search”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(isBusy)
        .navigationTitle("Connection")
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [UTType(filenameExtension: "pem") ?? .data],
                      allowsMultipleSelection: false) { result in
            importCertificate(result)
        }
        .sheet(isPresented: $showingAddServer) {
            AddServerView { client.servers.append($0) }
        }
    }

    // MARK: - Certificate

    private var certificateRow: some View {
        LabeledContent("Certificate") {
            HStack(spacing: 8) {
                Text(pemFileName ?? "None — password auth")
                    .foregroundStyle(pemFileName == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
