import Foundation
struct VoxVoice: Equatable, Sendable { enum Mode: Sendable { case clone }; var mode: Mode; var transcript: String; var reference: [Float]?; var continuation: [Float]?; var patches: Int }
enum ClonedVoiceWorkerError: Error, Equatable { case timeout }
