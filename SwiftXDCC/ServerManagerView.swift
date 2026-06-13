//
//  ServerManagerView.swift
//  SwiftXDCC
//
//  Created by Marek Skrzelowski on 13/06/2026.
//

import SwiftUI

/// Lists every configured server and lets the user add or remove custom ones.
struct ServerManagerView: View {
    let client: XDCCClient
    @State private var showingAdd = false

    var body: some View {
        List {
            ForEach(client.servers) { server in
                ServerRow(server: server)
                    .contextMenu {
                        if !server.isPredefined {
                            Button("Remove", role: .destructive) { remove(server) }
                        }
                    }
            }
        }
        .navigationTitle("Servers")
        .toolbar {
            Button {
                showingAdd = true
            } label: {
                Label("Add Server", systemImage: "plus")
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddServerView { newServer in
                client.servers.append(newServer)
            }
        }
    }

    private func remove(_ server: XDCCServer) {
        client.servers.removeAll { $0.id == server.id }
    }
}

/// One server row: hostname, an origin tag, and its channels with type chips.
private struct ServerRow: View {
    let server: XDCCServer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(server.hostname)
                    .font(.callout.weight(.medium))
                if !server.isPredefined {
                    Text("custom")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
            }

            ForEach(server.channels) { channel in
                HStack(spacing: 6) {
                    Text(channel.hashName)
                        .font(.system(.caption, design: .monospaced))
                    ForEach(channel.type, id: \.self) { type in
                        ChannelTypeChip(type: type)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Coloured capsule describing a channel type.
struct ChannelTypeChip: View {
    let type: XDCCChannelType

    var body: some View {
        Text(type.rawValue)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Self.color(for: type).opacity(0.2), in: Capsule())
            .foregroundStyle(Self.color(for: type))
    }

    static func color(for type: XDCCChannelType) -> Color {
        switch type {
        case .download: .green
        case .search: .blue
        case .request: .orange
        }
    }
}

/// Sheet that builds a custom ``XDCCServer`` from a hostname and a set of
/// channels, each tagged with one or more ``XDCCChannelType`` values.
struct AddServerView: View {
    let onAdd: (XDCCServer) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var hostname = ""
    @State private var channels: [XDCCChannel] = []
    @State private var channelName = ""
    @State private var selectedTypes: Set<XDCCChannelType> = [.search]

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("irc.example.net", text: $hostname)
                        .autocorrectionDisabled()
                }

                Section("Add channel") {
                    TextField("channel-name (without #)", text: $channelName)
                        .autocorrectionDisabled()
                    typeSelector
                    Button("Add channel", action: addChannel)
                        .disabled(!canAddChannel)
                }

                if !channels.isEmpty {
                    Section("Channels") {
                        ForEach(channels) { channel in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(channel.hashName)
                                    .font(.callout.weight(.medium))
                                HStack(spacing: 6) {
                                    ForEach(channel.type, id: \.self) { type in
                                        ChannelTypeChip(type: type)
                                    }
                                }
                            }
                        }
                        .onDelete { channels.remove(atOffsets: $0) }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!canSave)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
    }

    private var typeSelector: some View {
        HStack(spacing: 8) {
            ForEach(XDCCChannelType.allCases, id: \.self) { type in
                let isOn = selectedTypes.contains(type)
                Button {
                    if isOn { selectedTypes.remove(type) } else { selectedTypes.insert(type) }
                } label: {
                    Text(type.rawValue.capitalized)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(isOn ? Color.accentColor : Color.secondary.opacity(0.2),
                                    in: Capsule())
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var canAddChannel: Bool {
        !channelName.trimmingCharacters(in: .whitespaces).isEmpty && !selectedTypes.isEmpty
    }

    private var canSave: Bool {
        !hostname.trimmingCharacters(in: .whitespaces).isEmpty && !channels.isEmpty
    }

    private func addChannel() {
        let name = channelName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !selectedTypes.isEmpty else { return }
        // Keep a stable type order regardless of selection order.
        let types = XDCCChannelType.allCases.filter { selectedTypes.contains($0) }
        channels.append(XDCCChannel(name: name, type: types))
        channelName = ""
        selectedTypes = [.search]
    }

    private func save() {
        let host = hostname.trimmingCharacters(in: .whitespaces)
        onAdd(XDCCServer(hostname: host, channels: channels, isPredefined: false))
        dismiss()
    }
}
