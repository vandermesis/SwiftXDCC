//
//  ConnectionView.swift
//  SwiftXDCC
//
//  Created by Marek Skrzelowski on 13/06/2026.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Connection settings: shared IRC identity plus the selectable list of servers.
struct ConnectionView: View {
    @Bindable var client: XDCCClient

    @State private var showingImporter = false
    @State private var showingAddServer = false
    @State private var showingIdentityConfirmation = false
    @State private var identityAction: IdentityAction?
    @State private var exportedCertificate: PEMDocumentFile?
    @State private var showingExporter = false
    @State private var certificateError: String?
    @State private var confirmationCodes: [UUID: String] = [:]

    private var isBusy: Bool {
        client.status == .connecting || client.status == .registered
    }

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Nickname", text: $client.nick)
                    .autocorrectionDisabled()
                    .disabled(isBusy)
                SecureField("NickServ Password", text: $client.password)
                    .disabled(isBusy)
                certificateSection
                    .disabled(isBusy)
            }

            nickServAuthenticationSection

            if client.identityStore.identity != nil {
                certFPRegistrationSection
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
            .disabled(isBusy)
        }
        .formStyle(.grouped)
        .navigationTitle("Connection")
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [UTType(filenameExtension: "pem") ?? .data],
                      allowsMultipleSelection: false) { result in
            importCertificate(result)
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportedCertificate,
            contentType: UTType(filenameExtension: "pem") ?? .data,
            defaultFilename: "SwiftXDCC-Certificate.pem"
        ) { result in
            if case .failure(let error) = result {
                certificateError = error.localizedDescription
            }
        }
        .confirmationDialog(
            identityAction?.title ?? "Certificate",
            isPresented: $showingIdentityConfirmation,
            titleVisibility: .visible
        ) {
            Button(identityAction?.buttonTitle ?? "Continue", role: .destructive) {
                performIdentityAction()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(identityAction?.message ?? "")
        }
        .alert(
            "Certificate Error",
            isPresented: Binding(
                get: { certificateError != nil },
                set: { if !$0 { certificateError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(certificateError ?? "")
        }
        .sheet(isPresented: $showingAddServer) {
            AddServerView { client.servers.append($0) }
        }
    }

    // MARK: - Certificate

    private var certificateSection: some View {
        Group {
            if let identity = client.identityStore.identity {
                LabeledContent("Certificate") {
                    HStack(spacing: 8) {
                        Label(identity.source.label, systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text(identity.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                LabeledContent("SHA-256") {
                    HStack(spacing: 8) {
                        Text(identity.fingerprint)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                identity.fingerprint,
                                forType: .string
                            )
                        }
                        .buttonStyle(.borderless)
                    }
                }

                LabeledContent("Expires") {
                    Text(identity.expiresAt, format: .dateTime.year().month().day())
                }

                HStack {
                    Button("Export Public Certificate…") {
                        guard let pem = identity.certificatePEM else { return }
                        exportedCertificate = PEMDocumentFile(text: pem)
                        showingExporter = true
                    }

                    Spacer()

                    Button("Replace…") {
                        identityAction = .replace
                        showingIdentityConfirmation = true
                    }
                    Button("Delete", role: .destructive) {
                        identityAction = .delete
                        showingIdentityConfirmation = true
                    }
                }
            } else {
                LabeledContent("Certificate") {
                    Text("None — password authentication")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Generate Certificate") {
                        do {
                            try client.identityStore.generate(nickname: client.nick)
                            client.note("Generated and stored a new CertFP identity.")
                        } catch {
                            certificateError = error.localizedDescription
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Import PEM…") {
                        showingImporter = true
                    }
                }
            }
        }
    }

    private var nickServAuthenticationSection: some View {
        Section {
            ForEach(client.servers.filter(\.isEnabled)) { server in
                let state = client.nickServState(for: server)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: nickServSymbol(state))
                            .foregroundStyle(nickServColor(state))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.hostname)
                            Text(state.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()

                        if nickServCanRegister(state) {
                            Button("Register") {
                                client.registerNickServ(on: server)
                            }
                            .disabled(!client.isConnected(to: server))
                        }
                    }

                    if state == .awaitingConfirmation {
                        confirmationRow(for: server)
                    }
                }
            }
        } header: {
            Text("NickServ Authentication")
        } footer: {
            Text("SwiftXDCC identifies with your NickServ password on connect, before CertFP. If the nickname isn’t registered on a network yet, Register creates it with your password.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func confirmationRow(for server: XDCCServer) -> some View {
        let code = confirmationCodes[server.id] ?? ""
        return HStack(spacing: 8) {
            TextField("E-mail verification code", text: Binding(
                get: { confirmationCodes[server.id] ?? "" },
                set: { confirmationCodes[server.id] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .onSubmit { submitConfirmation(for: server) }

            Button("Register") {
                submitConfirmation(for: server)
            }
            .disabled(!client.isConnected(to: server)
                || code.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func submitConfirmation(for server: XDCCServer) {
        let code = confirmationCodes[server.id] ?? ""
        guard !code.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        client.confirmNickServRegistration(on: server, code: code)
        confirmationCodes[server.id] = ""
    }

    private var certFPRegistrationSection: some View {
        Section {
            ForEach(client.servers.filter(\.isEnabled)) { server in
                let state = client.certFPState(for: server)
                HStack(spacing: 10) {
                    Image(systemName: registrationSymbol(state))
                        .foregroundStyle(registrationColor(state))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.hostname)
                        Text(state.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    if state == .registered {
                        Button("Mark Unregistered") {
                            client.forgetCertificateRegistration(on: server)
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Button("Register") {
                            client.registerCertificate(on: server)
                        }
                        .disabled(!client.isConnected(to: server) || state == .registering)
                    }
                }
            }
        } header: {
            Text("CertFP Registration")
        } footer: {
            Text("Connect with your NickServ password, then register this certificate separately on each network. Successful registrations are remembered for future passwordless connections.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                let data = try Data(contentsOf: url)
                try client.identityStore.importPEM(data, displayName: url.lastPathComponent)
                client.note("Selected certificate: \(url.lastPathComponent)")
            } catch {
                certificateError = error.localizedDescription
                client.note("Failed to read certificate: \(error.localizedDescription)")
            }

        case .failure(let error):
            certificateError = error.localizedDescription
            client.note("Certificate import failed: \(error.localizedDescription)")
        }
    }

    private func performIdentityAction() {
        guard let action = identityAction else { return }
        do {
            switch action {
            case .replace:
                showingImporter = true
            case .delete:
                try client.identityStore.deleteIdentity()
                client.note("CertFP identity deleted; using password authentication.")
            }
        } catch {
            certificateError = error.localizedDescription
        }
        identityAction = nil
    }

    private func nickServSymbol(_ state: NickServAuthState) -> String {
        switch state {
        case .checking: "clock.arrow.circlepath"
        case .identified: "checkmark.circle.fill"
        case .awaitingConfirmation: "envelope.badge"
        case .failed: "xmark.circle.fill"
        case .needsRegistration: "exclamationmark.circle"
        case .unavailable: "minus.circle"
        }
    }

    private func nickServColor(_ state: NickServAuthState) -> Color {
        switch state {
        case .identified: .green
        case .checking: .blue
        case .awaitingConfirmation: .orange
        case .failed: .red
        case .needsRegistration: .orange
        case .unavailable: .secondary
        }
    }

    private func nickServCanRegister(_ state: NickServAuthState) -> Bool {
        switch state {
        case .failed, .needsRegistration: true
        case .checking, .identified, .awaitingConfirmation, .unavailable: false
        }
    }

    private func registrationSymbol(_ state: CertFPRegistrationState) -> String {
        switch state {
        case .unavailable: "questionmark.circle"
        case .needsRegistration: "exclamationmark.circle"
        case .registering: "clock.arrow.circlepath"
        case .registered: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private func registrationColor(_ state: CertFPRegistrationState) -> Color {
        switch state {
        case .registered: .green
        case .registering: .blue
        case .failed: .red
        default: .orange
        }
    }
}

private enum IdentityAction {
    case replace
    case delete

    var title: String {
        switch self {
        case .replace: "Replace CertFP Identity?"
        case .delete: "Delete CertFP Identity?"
        }
    }

    var message: String {
        switch self {
        case .replace:
            "The new fingerprint must be registered again on every IRC network."
        case .delete:
            "The private key will be removed from Keychain. Existing network registrations will no longer be usable."
        }
    }

    var buttonTitle: String {
        switch self {
        case .replace: "Choose Replacement"
        case .delete: "Delete Identity"
        }
    }
}

private struct PEMDocumentFile: FileDocument {
    static var readableContentTypes: [UTType] {
        [UTType(filenameExtension: "pem") ?? .data]
    }

    let text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
