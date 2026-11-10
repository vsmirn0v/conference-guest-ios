import AppKit
import Foundation

/// Owns the native MCP adapter lifecycle and exposes the one-time pairing flow.
@MainActor final class NativeDesktopMCPService {
    private let workspace: NativeDesktopWorkspace
    private let tokens = MCPTokenStore()
    private let backend: NativeDesktopMCPBackend
    private let rpc: MCPJSONRPCServer
    private let transport: MCPHTTPTransport
    private(set) var endpointFile: URL
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
        transport.onError = { [weak self] message in self?.onError(message) }
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
                transport.onError = { [weak self] message in self?.onError(message) }
                do { try await transport.start() } catch { onError("Unable to start MCP endpoint: \(error)") }
            } else { onError("Unable to start MCP endpoint: \(error)") }
        }
    }

    func stop() { transport.stop() }

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
