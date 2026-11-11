import Combine
import Darwin
import Foundation

/// A model's approximate contribution to this process's physical footprint.
struct ModelMemoryEstimate: Equatable, Sendable {
    let bytes: UInt64
    let measuredAt: Date
    let afterInference: Bool
}

/// A persisted measurement from an earlier session, keyed by model ID. Shown
/// only when no live estimate exists and always labeled with its date.
struct ModelMemoryRecord: Codable, Equatable, Sendable {
    var bytes: UInt64
    var measuredAt: Date
    var build: String
    var afterInference: Bool
}

/// Why a load produced no attributable memory figure.
enum ModelMemoryUnmeasuredReason: String, Equatable, Sendable {
    /// Another model loaded at the same time; the process-wide delta could not
    /// be attributed. Retried automatically on the role's next load.
    case contended
}

/// Total/used/available Mac memory. Values are estimates: macOS can reclaim
/// inactive and purgeable pages at any time.
struct LocalSystemMemorySnapshot: Equatable, Sendable {
    let total: UInt64
    let used: UInt64
    let available: UInt64
}

enum LocalModelMemoryRole: String, Hashable, Sendable {
    case speech, voice
}

struct LocalModelMemoryRuntimeState: Equatable, Sendable {
    var estimates: [LocalModelMemoryRole: ModelMemoryEstimate] = [:]
    var contended: Set<LocalModelMemoryRole> = []
    /// Roles whose most recent load could not be attributed (e.g. a concurrent
    /// load). Distinct from "no estimate": it explains why the number is missing.
    var unmeasured: [LocalModelMemoryRole: ModelMemoryUnmeasuredReason] = [:]
    var lastProcessFootprint: UInt64?
}

/// Event-driven footprint attribution around model load and inference.
///
/// Core ML and Core AI do not expose a public per-model memory counter. The
/// tracker samples the process footprint before and after a load and stores a
/// clearly approximate delta. Concurrent model loads are marked contended so
/// the same process-wide change is never attributed to two models.
final class LocalModelMemoryTracker: @unchecked Sendable {
    static let shared = LocalModelMemoryTracker()

    let runtime = CurrentValueSubject<LocalModelMemoryRuntimeState, Never>(.init())

    private struct ActiveMeasurement {
        let token: UUID
        let baseline: UInt64?
        var contended: Bool
    }

    private let queue = DispatchQueue(label: "attention.local-models.memory")
    private var state = LocalModelMemoryRuntimeState()
    private var active: [LocalModelMemoryRole: ActiveMeasurement] = [:]
    private var baselines: [LocalModelMemoryRole: UInt64] = [:]

    private init() {}

    /// Starts attribution for a load. A new measurement invalidates the
    /// previous estimate for the same role.
    @discardableResult
    func begin(_ role: LocalModelMemoryRole) -> UUID {
        queue.sync {
            let token = UUID()
            let baseline = ProcessMemoryProbe.footprint()
            active[role] = .init(token: token, baseline: baseline, contended: false)
            baselines[role] = nil
            state.estimates[role] = nil
            state.unmeasured[role] = nil
            if active.count > 1 {
                for key in active.keys { active[key]?.contended = true }
                state.contended.formUnion(active.keys)
            }
            state.lastProcessFootprint = baseline
            publish()
            return token
        }
    }

    /// Completes a load. A failed or contended measurement publishes no
    /// estimate; a contended one records an explicit unmeasured reason so the UI
    /// can explain the gap and the next load retries attribution.
    func complete(_ role: LocalModelMemoryRole, token: UUID, success: Bool) {
        queue.sync {
            guard let measurement = active[role], measurement.token == token else { return }
            let after = ProcessMemoryProbe.footprint()
            state.lastProcessFootprint = after
            baselines[role] = nil
            if success, !measurement.contended, let baseline = measurement.baseline, let after {
                let bytes = after > baseline ? after - baseline : 0
                state.estimates[role] = .init(bytes: bytes, measuredAt: Date(), afterInference: false)
                baselines[role] = baseline
                state.unmeasured[role] = nil
            } else {
                state.estimates[role] = nil
                if success, measurement.contended {
                    state.unmeasured[role] = .contended
                    probeLog("local-model-memory-contended", ["role": role.rawValue])
                } else {
                    state.unmeasured[role] = nil
                }
            }
            active[role] = nil
            state.contended.remove(role)
            publish()
        }
    }

    /// Refines an already-loaded estimate after inference has created lazy
    /// functions and buffers. Other app activity can still affect the result.
    func refine(_ role: LocalModelMemoryRole) {
        queue.sync {
            guard active.isEmpty, !state.contended.contains(role),
                  let current = state.estimates[role], let baseline = baselines[role],
                  let after = ProcessMemoryProbe.footprint() else { return }
            state.lastProcessFootprint = after
            let bytes = max(current.bytes, after > baseline ? after - baseline : 0)
            state.estimates[role] = .init(bytes: bytes, measuredAt: Date(), afterInference: true)
            publish()
        }
    }

    /// The speech helper measures its own baseline and post-inference footprint.
    func recordVoiceWorker(bytes: UInt64) {
        queue.sync {
            state.estimates[.voice] = .init(bytes: bytes, measuredAt: Date(), afterInference: true)
            publish()
        }
    }

    /// Releases an estimate and any in-flight attribution for a model.
    func clear(_ role: LocalModelMemoryRole) {
        queue.sync {
            active[role] = nil
            baselines[role] = nil
            state.estimates[role] = nil
            state.contended.remove(role)
            state.unmeasured[role] = nil
            state.lastProcessFootprint = ProcessMemoryProbe.footprint()
            publish()
        }
    }

    func resetForTesting() {
        queue.sync {
            active.removeAll()
            baselines.removeAll()
            state = .init(lastProcessFootprint: ProcessMemoryProbe.footprint())
            publish()
        }
    }

    private func publish() { runtime.send(state) }
}

enum LocalModelSystemMemoryProbe {
    /// Available memory is an estimate built from reclaimable VM counters. It is
    /// intended for orientation, not byte-for-byte equality with Activity Monitor.
    static func snapshot() -> LocalSystemMemorySnapshot? {
        let physical = UInt64(ProcessInfo.processInfo.physicalMemory)
        guard physical > 0 else { return nil }
        var pageSize = vm_size_t()
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }

        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pages = UInt64(statistics.free_count) + UInt64(statistics.inactive_count) +
            UInt64(statistics.speculative_count) + UInt64(statistics.purgeable_count)
        let available = min(physical, pages * UInt64(pageSize))
        return .init(total: physical, used: physical - min(physical, available), available: available)
    }
}
