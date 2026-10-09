#if DEBUG
import Foundation
import ObjectiveC

/// Feasibility probe for a documented Objective-C createDecoder: factory method.
/// Kept outside Release; returning nil preserves the original decoder exactly.
enum DecoderFactoryOverride {
    static func install(_ factory: AnyClass, make: @escaping (AnyObject) -> AnyObject?) -> Bool {
        let selector = NSSelectorFromString("createDecoder:")
        guard let method = class_getInstanceMethod(factory, selector), method_getNumberOfArguments(method) == 3,
              let encoding = method_getTypeEncoding(method), encoding.pointee == 64 else { return false }
        typealias Create = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject?
        let original = unsafeBitCast(method_getImplementation(method), to: Create.self)
        let forward: @convention(block) (AnyObject, AnyObject) -> AnyObject? = { factory, info in
            make(info) ?? original(factory, selector, info)
        }
        let replacement = imp_implementationWithBlock(forward)
        if !class_addMethod(factory, selector, replacement, encoding) { method_setImplementation(method, replacement) }
        return true
    }
}
#endif
