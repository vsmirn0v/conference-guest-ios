// Production declarations are supplied verbatim by run-r4-policy-tests.py.
@main struct VPIOPolicyTests {
    static func main() {
        for bits in 0..<256 {
            func bit(_ n: Int) -> Bool { bits & (1 << n) != 0 }
            let context = GuestVPIOReleasePolicy.Context(meetingOwner: bit(0), authorized: bit(1),
                audioEngine: bit(2), voiceProcessing: bit(3), route: bit(4) ? .builtIn : .otherOrUnknown,
                playoutRequested: bit(5), outputRunning: bit(6), inputAvailable: bit(7))
            let eligible = (0...5).allSatisfy { bit($0) } && !bit(7)
            precondition(GuestVPIOReleasePolicy.builtInPreparedPrivateR3.prepareStoppedInput(context) == eligible)
            precondition(GuestVPIOReleasePolicy.builtInPreparedPrivateR3.privateCheck(context) == (eligible && bit(6) ? .isolated : .existing))
            precondition(!GuestVPIOReleasePolicy.existing.prepareStoppedInput(context))
            precondition(GuestVPIOReleasePolicy.existing.privateCheck(context) == .existing)
        }
        #if ROCK_VPIO_BUILTIN_RELEASE
        precondition(GuestVPIOReleasePolicy.selected == .builtInPreparedPrivateR3)
        #else
        precondition(GuestVPIOReleasePolicy.selected == .existing)
        #endif
        var lease = GuestPrivateInputLeasePolicy()
        let first = lease.reserve()!
        precondition(lease.commitMeter(first, at: 10))
        let network = lease.beginNetworkActivation()
        precondition(network.allowed && network.token == first && !lease.isLive(first))
        precondition(lease.reserve() == nil && !lease.commitMeter(first, at: 11))
        precondition(lease.finish(first) && lease.reserve() == nil)
        lease.endNetworkActivation()
        let second = lease.reserve()!
        precondition(second > first && !lease.finish(first) && lease.isLive(second))
        precondition(lease.close() == second && !lease.isLive(second))
        precondition(lease.finish(second) && lease.reserve() == nil && !lease.beginNetworkActivation().allowed)
        var failed = GuestPrivateInputLeasePolicy()
        let token = failed.reserve()!; failed.quarantine()
        precondition(!failed.isLive(token) && failed.reserve() == nil && !failed.beginNetworkActivation().allowed)
        precondition(failed.finish(token) && failed.reserve() == nil)
        print("PASS 256 contexts for each policy, build selection, network drain, stale token, close and quarantine")
    }
}
