import AppKit
import SwiftUI

/// Settings panel for the app's local MCP server: reachability, pairing,
/// paired clients and the exact tool surface an AI client gets.
struct NativeDesktopMCPSettings: View {
    @ObservedObject var service: NativeDesktopMCPService
    @State private var copiedEndpoint = false
    @State private var copiedPairing = false

    private var readOnlyTools: [MCPToolDefinition] { nativeMCPToolDefinitions().filter(\.readOnly) }
    private var writeTools: [MCPToolDefinition] { nativeMCPToolDefinitions().filter { !$0.readOnly } }

    var body: some View {
        Form {
            Section(L("Server")) {
                HStack(alignment: .firstTextBaseline) {
                    Circle().fill(service.status.running ? Color.green : Color.red).frame(width: 8, height: 8)
                    if service.status.running, let port = service.status.port {
                        Text(L("Running on this Mac · port %u", port))
                    } else {
                        Text(L("Not running"))
                    }
                    Spacer()
                    if !service.status.running {
                        Button(L("Start")) { Task { await service.start() } }
                    }
                }
                if let error = service.status.error {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Endpoint file")).foregroundStyle(.secondary)
                        Text(service.status.endpointFilePath).font(.caption).lineLimit(2)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button(copiedEndpoint ? L("Copied") : L("Copy")) {
                        copy(service.status.endpointFilePath, flag: \.copiedEndpoint)
                    }
                }
                Text(L("The endpoint file tells MCP clients where to connect. AI clients on this Mac read it to find the server."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(L("Pairing")) {
                Button(copiedPairing ? L("Copied") : L("Copy pairing instructions")) {
                    copy(service.makePairingInstruction(), flag: \.copiedPairing)
                }
                .disabled(!service.status.running)
                Text(L("Copies the endpoint and a fresh single-use pairing token. Paste them into your AI client (for example its rocknroll-native connector) to pair it; every pair rotates the token."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(L("Paired clients")) {
                if service.status.pairedClients.isEmpty {
                    Text(L("No AI clients are paired.")).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(service.status.pairedClients, id: \.tokenHash) { client in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(client.label)
                            Text(client.scopes.sorted().joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("Remove")) { service.revokeClient(client) }
                    }
                }
                if !service.status.pairedClients.isEmpty {
                    Text(L("Removing a client revokes its token immediately.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L("Read-only tools · %d", readOnlyTools.count)) {
                Text(L("Available to every paired client. They never change anything.")).font(.caption).foregroundStyle(.secondary)
                ForEach(readOnlyTools, id: \.name) { tool in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name).font(.system(.body, design: .monospaced))
                        Text(tool.description).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section(L("Tools that ask first · %d", writeTools.count)) {
                Text(L("A paired client with write scopes can request these; the app shows an Allow/Deny alert before anything happens, and every action is recorded."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(writeTools, id: \.name) { tool in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name).font(.system(.body, design: .monospaced))
                        Text(tool.description).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.padding(20).formStyle(.grouped)
            .onDisappear { copiedEndpoint = false; copiedPairing = false }
    }

    private func copy(_ text: String, flag: ReferenceWritableKeyPath<NativeDesktopMCPSettings, Bool>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        self[keyPath: flag] = true
    }
}
