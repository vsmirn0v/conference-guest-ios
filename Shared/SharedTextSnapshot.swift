import CoreImage
import CoreGraphics
import CoreVideo
import Foundation
import Vision
import VisionKit

/// A local, immutable image. It never follows the producer's reused buffers.
struct SharedTextSnapshot: @unchecked Sendable {
    let id: UUID
    let sourceID: String
    let sourceName: String
    let capturedAt: Date
    let image: CGImage

    init(image: CGImage, sourceID: String, sourceName: String, capturedAt: Date = Date()) {
        id = UUID(); self.image = image; self.sourceID = sourceID
        self.sourceName = sourceName; self.capturedAt = capturedAt
    }
}

enum SharedTextImage {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func oriented(_ pixels: CVPixelBuffer, rotation: Int, mirrored: Bool = false) -> CIImage? {
        var image = CIImage(cvPixelBuffer: pixels)
        switch rotation {
        case 0: break
        case 90: image = image.oriented(.right)
        case 180: image = image.oriented(.down)
        case 270: image = image.oriented(.left)
        default: return nil
        }
        if mirrored { image = image.oriented(.upMirrored) }
        return image
    }

    /// Called only for an explicit capture, never for each received video frame.
    static func materialize(_ image: CIImage) -> CGImage? {
        guard image.extent.width > 0, image.extent.height > 0,
              image.extent.width <= 16_384, image.extent.height <= 16_384,
              image.extent.width * image.extent.height <= 40_000_000 else { return nil }
        return context.createCGImage(image, from: image.extent, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB), deferred: false)
    }
}

/// Analysis completion belongs to one captured image, even if its live source ends.
struct SharedTextAnalysisIdentity: Equatable {
    let meeting: UUID
    let snapshot: UUID
}

enum SharedTextLiveState: Equatable {
    case same, ended, changed
    static func resolve(capturedSource: String, currentSource: String?) -> Self {
        guard let currentSource else { return .ended }
        return currentSource == capturedSource ? .same : .changed
    }
}

/// A canceled UI task can still be waiting for system OCR or image conversion.
/// Keep the process-wide permit until that work actually returns, rather than
/// allowing repeated close/open gestures to start overlapping expensive jobs.
final class SharedTextWorkAdmission: @unchecked Sendable {
    static let shared = SharedTextWorkAdmission()
    static let didChange = Notification.Name("SharedTextWorkAdmission.didChange")
    private let lock = NSLock()
    private var active: UUID?
    var isOccupied: Bool { lock.lock(); defer { lock.unlock() }; return active != nil }
    func acquire() -> UUID? {
        lock.lock()
        guard active == nil else { lock.unlock(); return nil }
        let token = UUID(); active = token; lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        return token
    }
    func release(_ token: UUID) {
        lock.lock()
        guard active == token else { lock.unlock(); return }
        active = nil; lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

enum SharedTextRecognitionResult: @unchecked Sendable {
    case native(ImageAnalysis)
    case transcript(String)
}

/// One instance belongs to a UI capture workflow. Its worker outlives the UI
/// when a system framework ignores task cancellation; no UI object is captured.
final class SharedTextRecognizer: @unchecked Sendable {
    private let analyzer = ImageAnalyzer()
    func recognize(_ image: CGImage) async throws -> SharedTextRecognitionResult {
        if ImageAnalyzer.isSupported {
            return .native(try await analyzer.analyze(image, orientation: .up, configuration: .init([.text])))
        }
        return try await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false; request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            return .transcript(request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? "")
        }.value
    }
}

/// The deadline bounds UI waiting, not the lifetime of framework work. A timed
/// out job keeps its permit until the real capture/analysis operation returns.
@MainActor final class SharedTextJob {
    typealias Recognition = (CGImage) async throws -> SharedTextRecognitionResult
    enum Failure: Equatable { case captureUnavailable, recognition }
    private var worker: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var acceptsResults = true
    private var snapshotID: UUID?
    private var onCapture: ((SharedTextSnapshot) -> Void)?
    private var onResult: ((SharedTextRecognitionResult) -> Void)?
    private var onFailure: ((Failure) -> Void)?
    private var onTimeout: (() -> Void)?
    private var onFinished: (() -> Void)?

    static func start(timeout: Duration, capture: @escaping @MainActor () async -> SharedTextSnapshot?,
        recognize: @escaping Recognition, onCapture: @escaping (SharedTextSnapshot) -> Void,
        onResult: @escaping (SharedTextRecognitionResult) -> Void, onFailure: @escaping (Failure) -> Void,
        onTimeout: @escaping () -> Void, onFinished: @escaping () -> Void) -> SharedTextJob? {
        guard let permit = SharedTextWorkAdmission.shared.acquire() else { return nil }
        let job = SharedTextJob()
        job.onCapture = onCapture; job.onResult = onResult; job.onFailure = onFailure
        job.onTimeout = onTimeout; job.onFinished = onFinished
        job.deadline = Task { [weak job] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let job, job.acceptsResults else { return }
            job.acceptsResults = false; job.onTimeout?()
        }
        job.worker = Task { [weak job] in
            defer {
                job?.workerFinished()
                SharedTextWorkAdmission.shared.release(permit)
            }
            guard !Task.isCancelled, job?.acceptsResults == true else { return }
            let captured = await capture()
            guard !Task.isCancelled else { return }
            guard let captured else { job?.failed(.captureUnavailable); return }
            guard job?.captured(captured) == true else { return }
            guard !Task.isCancelled else { return }
            do {
                let result = try await recognize(captured.image)
                guard !Task.isCancelled else { return }
                job?.completed(result, snapshotID: captured.id)
            } catch {
                guard !Task.isCancelled else { return }
                job?.failed(.recognition)
            }
        }
        return job
    }
    private func captured(_ snapshot: SharedTextSnapshot) -> Bool {
        guard acceptsResults else { return false }
        snapshotID = snapshot.id; onCapture?(snapshot); return acceptsResults
    }
    private func completed(_ result: SharedTextRecognitionResult, snapshotID: UUID) {
        guard acceptsResults, self.snapshotID == snapshotID else { return }
        acceptsResults = false; deadline?.cancel(); deadline = nil; onResult?(result)
    }
    private func failed(_ failure: Failure) {
        guard acceptsResults else { return }
        acceptsResults = false; deadline?.cancel(); deadline = nil; onFailure?(failure)
    }
    private func workerFinished() { deadline?.cancel(); deadline = nil; worker = nil; onFinished?() }
    func cancelUI() {
        acceptsResults = false; deadline?.cancel(); deadline = nil; worker?.cancel(); worker = nil
        onCapture = nil; onResult = nil; onFailure = nil; onTimeout = nil; onFinished = nil
    }
    deinit { deadline?.cancel(); worker?.cancel() }
}
