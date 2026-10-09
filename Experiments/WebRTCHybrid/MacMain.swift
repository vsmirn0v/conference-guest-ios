@main struct MacMain {
    @MainActor static func main() async throws { try await HybridLoopback.run() }
}
