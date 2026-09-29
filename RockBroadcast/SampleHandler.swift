import LiveKit

final class SampleHandler: LKSampleHandler {
    #if DEBUG
    override var enableLogging: Bool { true }
    #endif
}
