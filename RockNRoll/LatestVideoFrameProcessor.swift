import Foundation
import QuartzCore

/// A bounded, event-driven display pipeline: one conversion, one newest input,
/// and one newest output waiting for the UI. No repeating timer or catch-up burst.
final class LatestVideoFrameProcessor<Input, Output>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let convert: (Input) -> Output?
    private let deliver: @MainActor (Output) -> Void
    private var source = UUID()
    private var generation: UInt64 = 0
    private var enabled = false
    private var busy = false
    private var scheduled = false
    private var deliveryScheduled = false
    private var pending: Input?
    private var output: (UInt64, Output)?
    private var deadline: TimeInterval?
    private var interval: TimeInterval = 1 / 30

    init(label: String, convert: @escaping (Input) -> Output?,
         deliver: @escaping @MainActor (Output) -> Void) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        self.convert = convert; self.deliver = deliver
    }

    func setEnabled(_ value: Bool) {
        lock.lock()
        if enabled != value {
            enabled = value; generation &+= 1
            pending = nil; output = nil; deadline = nil; scheduled = false
        }
        lock.unlock()
    }

    func replaceSource() -> UUID {
        lock.lock(); defer { lock.unlock() }
        source = UUID(); generation &+= 1; enabled = false
        pending = nil; output = nil; deadline = nil; scheduled = false
        return source
    }

    func setFrameRate(_ fps: Int) {
        let next = 1 / Double(max(1, fps))
        lock.lock()
        if interval != next { interval = next; deadline = nil }
        lock.unlock()
        drain()
    }

    func submit(_ input: Input, source expected: UUID? = nil) {
        lock.lock()
        guard enabled, expected == nil || expected == source else { lock.unlock(); return }
        pending = input
        lock.unlock()
        drain()
    }

    private func drain() {
        lock.lock()
        guard enabled, !busy, let input = pending else { lock.unlock(); return }
        let now = CACurrentMediaTime()
        if let deadline, now < deadline {
            if !scheduled {
                scheduled = true
                let expected = generation
                queue.asyncAfter(deadline: .now() + (deadline - now)) { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let current = self.generation == expected
                    if current { self.scheduled = false }
                    self.lock.unlock()
                    if current { self.drain() }
                }
            }
            lock.unlock(); return
        }
        pending = nil; busy = true
        // Advance the existing phase, rather than accumulating scheduler delay.
        // A long gap starts a fresh phase instead of replaying missed deadlines.
        if let deadline, now - deadline < interval { self.deadline = deadline + interval }
        else { deadline = now + interval }
        let expected = generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let current = self.enabled && self.generation == expected; self.lock.unlock()
            let result = current ? autoreleasepool { self.convert(input) } : nil
            self.lock.lock()
            self.busy = false
            if self.enabled && self.generation == expected, let result {
                self.output = (expected, result)
                if !self.deliveryScheduled {
                    self.deliveryScheduled = true
                    DispatchQueue.main.async { [weak self] in self?.deliverLatest() }
                }
            }
            self.lock.unlock()
            self.drain()
        }
    }

    @MainActor private func deliverLatest() {
        lock.lock()
        deliveryScheduled = false
        let latest = output; output = nil
        let current = enabled && latest?.0 == generation
        lock.unlock()
        if current, let latest { deliver(latest.1) }
    }
}
