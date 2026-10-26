import AVFoundation
import Foundation

/// A human permission decision has no device-startup deadline. Cancellation
/// releases the caller immediately; a later system reply cannot revive it.
@MainActor enum GuestCaptureAuthorization {
    static func request(_ type: AVMediaType) async throws -> Bool {
        try await request(status: { AVCaptureDevice.authorizationStatus(for: type) },
                          prompt: { AVCaptureDevice.requestAccess(for: type, completionHandler: $0) })
    }

    static func request(status: () -> AVAuthorizationStatus,
                        prompt: (@escaping (Bool) -> Void) -> Void) async throws -> Bool {
        try Task.checkCancellation()
        switch status() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            let completion = Completion()
            return try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                let allowed = try await withCheckedThrowingContinuation { continuation in
                    guard completion.install(continuation) else { return }
                    prompt { completion.finish(.success($0)) }
                }
                try Task.checkCancellation()
                return allowed
            }, onCancel: { completion.finish(.failure(CancellationError())) })
        @unknown default: return false
        }
    }

    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Error>?
        private var result: Result<Bool, Error>?
        func install(_ continuation: CheckedContinuation<Bool, Error>) -> Bool {
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result); return false }
            self.continuation = continuation; lock.unlock(); return true
        }
        func finish(_ result: Result<Bool, Error>) {
            lock.lock()
            guard self.result == nil else { lock.unlock(); return }
            self.result = result
            let continuation = self.continuation; self.continuation = nil
            lock.unlock(); continuation?.resume(with: result)
        }
    }
}
