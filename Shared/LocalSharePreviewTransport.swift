import CoreImage
import Foundation
import Network
import UIKit

/// Older ReplayKit broadcasts run in another process. Only a bounded thumbnail
/// crosses authenticated loopback; pixels are never written to the app group.
struct LocalSharePreviewEndpoint: Codable {
    let port: UInt16
    let token: String
    var wantsFrames: Bool
    static var url: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "RTCAppGroupIdentifier") as? String else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("local-share-preview-endpoint.json")
    }
    static let maximumBytes = 128 * 1024
}

final class LocalSharePreviewReceiver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.vsmirn0v.conferenceguest.local-preview.receive")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var endpoint: LocalSharePreviewEndpoint?
    private var wanted = false
    private var delivering = false
    private var epoch = UUID()
    var onReady: (@Sendable () -> Void)?

    func start(onImage: @escaping @MainActor @Sendable (UIImage) -> Void) {
        queue.async { [weak self] in
            guard let self, self.listener == nil else { return }
            let token = UUID().uuidString
            let epoch = UUID()
            self.epoch = epoch
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            do {
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, self.epoch == epoch, case .ready = state, let port = listener?.port else { return }
                    self.endpoint = .init(port: port.rawValue, token: token, wantsFrames: self.wanted)
                    self.writeEndpoint()
                    self.onReady?()
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self, self.epoch == epoch, self.connection == nil, !self.delivering else { connection.cancel(); return }
                    self.connection = connection
                    connection.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + 3) { [weak self, weak connection] in
                        guard let self, let connection, self.connection === connection else { return }
                        self.finish(connection)
                    }
                    self.receiveHeader(connection, token: token, epoch: epoch, onImage: onImage)
                }
                listener.start(queue: self.queue)
            } catch { self.stopOnQueue() } // Optional preview must never break the call.
        }
    }

    func setWanted(_ wanted: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.wanted = wanted
            self.endpoint?.wantsFrames = wanted
            self.writeEndpoint()
        }
    }
    func stop() { queue.async { self.stopOnQueue() } }
    private func stopOnQueue() {
        epoch = UUID()
        connection?.cancel(); connection = nil
        listener?.cancel(); listener = nil
        endpoint = nil; wanted = false
        if let url = LocalSharePreviewEndpoint.url { try? FileManager.default.removeItem(at: url) }
    }
    private func writeEndpoint() {
        guard let endpoint, let url = LocalSharePreviewEndpoint.url,
              let data = try? JSONEncoder().encode(endpoint) else { return }
        try? data.write(to: url, options: .atomic)
    }
    private func finish(_ connection: NWConnection) {
        connection.cancel()
        if self.connection === connection { self.connection = nil }
    }
    private func receiveHeader(_ connection: NWConnection, token: String, epoch: UUID,
                               onImage: @escaping @MainActor @Sendable (UIImage) -> Void) {
        connection.receive(minimumIncompleteLength: 40, maximumLength: 40) { [weak self] data, _, _, error in
            guard let self else { connection.cancel(); return }
            guard self.epoch == epoch, error == nil, let data, data.count == 40,
                  String(data: data.prefix(36), encoding: .utf8) == token else { self.finish(connection); return }
            let size = data.suffix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard (1...LocalSharePreviewEndpoint.maximumBytes).contains(size) else { self.finish(connection); return }
            connection.receive(minimumIncompleteLength: size, maximumLength: size) { [weak self] data, _, _, error in
                guard let self else { connection.cancel(); return }
                defer { self.finish(connection) }
                guard self.epoch == epoch, self.wanted, error == nil, let data, data.count == size,
                      let image = UIImage(data: data), image.size.width <= 640, image.size.height <= 640 else { return }
                self.delivering = true
                Task { [self] in
                    await onImage(image)
                    self.queue.async { self.delivering = false }
                }
            }
        }
    }
    deinit { listener?.cancel(); connection?.cancel() }
}

final class LocalSharePreviewSender: @unchecked Sendable {
    private let lock = NSLock()
    private var lastFrame: TimeInterval = -.infinity
    private var pending = false
    private lazy var context = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "dev.vsmirn0v.conferenceguest.local-preview.send")
    private var connection: NWConnection?
    func send(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard !pending, now - lastFrame >= 1 else { lock.unlock(); return }
        lastFrame = now
        guard let url = LocalSharePreviewEndpoint.url, let data = try? Data(contentsOf: url),
              let endpoint = try? JSONDecoder().decode(LocalSharePreviewEndpoint.self, from: data),
              endpoint.wantsFrames, endpoint.token.utf8.count == 36 else { lock.unlock(); return }
        pending = true
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let input = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
            let scale = min(1, 640 / max(input.extent.width, input.extent.height))
            let thumbnail = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cg = self.context.createCGImage(thumbnail, from: thumbnail.extent),
                  let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.65),
                  jpeg.count <= LocalSharePreviewEndpoint.maximumBytes else { self.complete(); return }
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: endpoint.port)!, using: .tcp)
            self.connection = connection
            let size = UInt32(jpeg.count)
            var packet = Data(endpoint.token.utf8)
            packet.append(contentsOf: [UInt8((size >> 24) & 255), UInt8((size >> 16) & 255),
                                      UInt8((size >> 8) & 255), UInt8(size & 255)])
            packet.append(jpeg)
            connection.start(queue: self.queue)
            connection.send(content: packet, completion: .contentProcessed { [weak self, weak connection] _ in
                guard let self, self.connection === connection else { return }
                self.connection?.cancel(); self.connection = nil; self.complete()
            })
            self.queue.asyncAfter(deadline: .now() + 3) { [weak self, weak connection] in
                guard let self, self.connection === connection else { return }
                self.connection?.cancel(); self.connection = nil; self.complete()
            }
        }
    }
    private func complete() { lock.lock(); pending = false; lock.unlock() }
    deinit { connection?.cancel() }
}
