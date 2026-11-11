import Darwin

enum ProcessMemoryProbe {
    static func footprint() -> UInt64? {
        var usage = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0)
            }
        }
        guard result == 0 else { return nil }
        return UInt64(usage.ri_phys_footprint)
    }
}
