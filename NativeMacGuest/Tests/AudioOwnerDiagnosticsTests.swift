import Foundation

@main
struct AudioOwnerDiagnosticsTests {
    static func main() {
        var leases: [GuestAudioOwnerLease] = []
        for _ in 0..<20 {
            guard let lease = GuestAudioOwnerLease(privateCheck: false, concurrent: true) else {
                fatalError("concurrent owner unexpectedly refused")
            }
            leases.append(lease)
        }
        let snapshot = GuestAudioOwnerLease.ownershipDiagnostics
        precondition(snapshot["count"] as? Int == 20)
        let entries = snapshot["leases"] as? [[String: Any]] ?? []
        precondition(entries.count == 16 && snapshot["truncated"] as? Int == 4)
        precondition(Set(entries.compactMap { $0["id"] as? String }).count == 16)
        precondition(JSONSerialization.isValidJSONObject(snapshot))
        precondition(GuestAudioOwnerLease(privateCheck: true) == nil)
        leases.removeAll()
        precondition(GuestAudioOwnerLease.ownershipDiagnostics["count"] as? Int == 0)
        print("Audio owner diagnostics: bounded and admission unchanged")
    }
}
