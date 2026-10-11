import Foundation
import QuartzCore

/// A bounded, event-driven display pipeline: one conversion, one newest input,
/// and one newest output waiting for the UI. No repeating timer or catch-up burst.
final class LatestVideoFrameProcessor<Input, Output>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let convert: (Input) -> Output?
    private let deliver: (@MainActor (Output) -> Void)?
    private let onPrepared: ((Output) -> Void)?
    private var source = UUID()
    private var generation: UInt64 = 0
    private var enabled = false
    private var mainDeliveryEnabled = true
    private var busy = false
    private var scheduled = false
    private var deliveryScheduled = false
    private struct Pending { let input: Input
        #if DEBUG
        let arrival: Double
        #endif
    }
    private var pending: Pending?
    private struct Prepared { let generation: UInt64; let value: Output
        #if DEBUG
        let arrival: Double; let start: Double; let ready: Double
        #endif
    }
    private var output: Prepared?
    #if DEBUG
    private let label: String
    private var timingObserver: ((ReceiveVideoTiming.Sample) -> Void)?
    var onTimingForTesting: ((ReceiveVideoTiming.Sample) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return timingObserver }
        set { lock.lock(); timingObserver = newValue; lock.unlock() }
    }
    private func timing(_ prepared: Prepared) {
        let delivered = CACurrentMediaTime()
        if ReceiveVideoTiming.enabled { ReceiveVideoTiming.shared.record(label: label, arrival: prepared.arrival, start: prepared.start, ready: prepared.ready, delivered: delivered) }
        onTimingForTesting?(.init(queueMS: (prepared.start - prepared.arrival) * 1000, conversionMS: (prepared.ready - prepared.start) * 1000, deliveryMS: (delivered - prepared.ready) * 1000))
    }
    #endif
    private var deadline: TimeInterval?
    private var interval: TimeInterval = 1 / 30

    init(label: String, convert: @escaping (Input) -> Output?,
         onPrepared: ((Output) -> Void)? = nil, deliver: @escaping @MainActor (Output) -> Void) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        #if DEBUG
        self.label = label
        #endif
        self.convert = convert; self.deliver = deliver; self.onPrepared = onPrepared
    }

    init(label: String, convert: @escaping (Input) -> Output?, backgroundDeliver: @escaping (Output) -> Void) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        #if DEBUG
        self.label = label
        #endif
        self.convert = convert; deliver = nil; onPrepared = backgroundDeliver
    }

    func setEnabled(_ value: Bool) {
        lock.lock()
        if enabled != value {
            enabled = value; generation &+= 1
            pending = nil; output = nil; deadline = nil; scheduled = false
        }
        lock.unlock()
    }

    func setMainDeliveryEnabled(_ value: Bool) {
        lock.lock(); mainDeliveryEnabled = value
        if !value { output = nil }
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
        #if DEBUG
        pending = Pending(input: input, arrival: CACurrentMediaTime())
        #else
        pending = Pending(input: input)
        #endif
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
            #if DEBUG
            let start = CACurrentMediaTime()
            #endif
            let result = current ? autoreleasepool { self.convert(input.input) } : nil
            #if DEBUG
            let ready = CACurrentMediaTime()
            #endif
            let prepared = result.map { value in
                #if DEBUG
                Prepared(generation: expected, value: value, arrival: input.arrival, start: start, ready: ready)
                #else
                Prepared(generation: expected, value: value)
                #endif
            }
            self.lock.lock()
            self.busy = false
            let accepted = self.enabled && self.generation == expected
            #if DEBUG
            let waitForMain = self.deliver != nil && self.mainDeliveryEnabled
            #endif
            self.lock.unlock()
            // The receiver owns its source token, so retirement also rejects a
            // callback already leaving this queue. No UIKit in this callback.
            if accepted, let prepared {
                self.onPrepared?(prepared.value)
                #if DEBUG
                if !waitForMain { self.timing(prepared) }
                #endif
            }
            self.lock.lock()
            if self.deliver != nil, self.mainDeliveryEnabled, self.enabled && self.generation == expected, let prepared {
                self.output = prepared
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
        let current = enabled && mainDeliveryEnabled && latest?.generation == generation
        lock.unlock()
        if current, let latest {
            deliver?(latest.value)
            #if DEBUG
            timing(latest)
            #endif
        }
    }
}
