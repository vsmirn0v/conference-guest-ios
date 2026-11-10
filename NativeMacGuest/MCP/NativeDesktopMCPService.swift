import AppKit
import Foundation

/// One renderable snapshot of the server for the settings panel.
struct NativeDesktopMCPStatus: Equatable {
    var running = false
    var port: UInt16?
    var endpointFilePath = ""
    var error: String?
    var pairedClients: [MCPClientIdentity] = []
}

/// Owns the native MCP adapter lifecycle and exposes the one-time pairing flow.
@MainActor final class NativeDesktopMCPService: ObservableObject {
    private let workspace: NativeDesktopWorkspace
    private let tokens = MCPTokenStore()
    private let backend: NativeDesktopMCPBackend
    /// The tool authority behind the service, for the in-app assistant's loopback provider.
    var toolBackend: any MCPBackend { backend }
    private let rpc: MCPJSONRPCServer
    private let transport: MCPHTTPTransport
    private(set) var endpointFile: URL
    @Published private(set) var status = NativeDesktopMCPStatus()
    var pairingToken: String { tokens.endpoint(host: "127.0.0.1", port: transport.port ?? 0, path: "/mcp").pairingToken }
    var isRunning: Bool { transport.port != nil }
    var onError: (String) -> Void = { message in NSLog("Rock'N'Roll MCP: %@", message) }

    init(workspace: NativeDesktopWorkspace, endpointFile: URL? = nil, approval: ((String, MCPJSON) async -> Bool)? = nil) {
        self.workspace = workspace
        let configured = endpointFile ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/rocknroll-mcp/endpoint.json", isDirectory: false)
        self.endpointFile = configured
        backend = NativeDesktopMCPBackend(workspace: { [weak workspace] in workspace }, approval: approval ?? { _, _ in
            await NativeDesktopMCPApproval.request(title: "Allow Rock'N'Roll action?", detail: "An AI agent requested a sensitive app action.")
        })
        rpc = MCPJSONRPCServer(backend: backend)
        transport = MCPHTTPTransport(server: rpc, tokens: tokens, endpointFile: configured)
        transport.onError = { [weak self] message in self?.handleTransportError(message) }
        tokens.onChange = { [weak self] in self?.refreshStatus() }
        refreshStatus()
    }

    /// Forgets one paired client; its token stops working immediately.
    func revokeClient(_ client: MCPClientIdentity) { tokens.revoke(tokenHash: client.tokenHash) }

    private func handleTransportError(_ message: String) {
        refreshStatus(error: message)
        onError(message)
    }

    private func refreshStatus(error: String? = nil) {
        status = NativeDesktopMCPStatus(running: isRunning, port: transport.port,
                                        endpointFilePath: endpointFile.path,
                                        error: error ?? (isRunning ? nil : status.error),
                                        pairedClients: tokens.pairedClients)
    }

    func start() async {
        guard !isRunning else { return }
        do { try await transport.start() }
        catch {
            let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("RockNRMCP/endpoint.json", isDirectory: false)
            if fallback != endpointFile {
                endpointFile = fallback
                transport.updateEndpointFile(fallback)
                transport.stop()
                transport.onError = { [weak self] message in self?.handleTransportError(message) }
                do {
                    try await transport.start()
                    refreshStatus()
                } catch {
                    let message = "Unable to start MCP endpoint: \(error)"
                    refreshStatus(error: message)
                    onError(message)
                }
            } else {
                let message = "Unable to start MCP endpoint: \(error)"
                refreshStatus(error: message)
                onError(message)
            }
        }
        refreshStatus()
    }

    func stop() {
        transport.stop()
        refreshStatus()
    }

    /// Issues a fresh pairing token and endpoint description for the user to approve.
    func makePairingInstruction() -> String {
        tokens.resetPairingToken()
        let endpoint = tokens.endpoint(host: "127.0.0.1", port: transport.port ?? 0, path: "/mcp")
        return "Endpoint file: \(endpointFile.path)\nPairing token: \(endpoint.pairingToken)"
    }
}

enum NativeDesktopMCPApproval {
    static func request(title: String, detail: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = title; alert.informativeText = detail
                alert.addButton(withTitle: NSLocalizedString("Allow", comment: "Approve a sensitive MCP action"))
                alert.addButton(withTitle: NSLocalizedString("Deny", comment: "Reject a sensitive MCP action"))
                continuation.resume(returning: alert.runModal() == .alertFirstButtonReturn)
            }
        }
    }
}
