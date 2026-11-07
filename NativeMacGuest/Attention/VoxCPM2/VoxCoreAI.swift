#if canImport(CoreAI)
import CoreAI
import Foundation

// In-process Core AI stages for the VoxCPM2 bundle, ported from tinkerbox-ane's Swift host
// (host.swift and cached.swift, Apache-2.0). Only public Core AI API is used: the first load
// on a Mac compiles each asset for its Neural Engine (minutes), later loads reuse the cache.

@available(macOS 27.0, *)
enum VoxCoreAI {
    static let options: SpecializationOptions = {
        var options = SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
        options.expectFrequentReshapes = false
        return options
    }()

    /// This Mac's Neural Engine architecture, as named in bundle file names (for example "h16g").
    static var architecture: String { AIModel.deviceArchitectureName }

    static func load(_ url: URL) async throws -> AIModel {
        // Core AI rejects an asset directory that is itself a symbolic link.
        let resolved = url.resolvingSymlinksInPath()
        do {
            return try await AIModel.specialize(contentsOf: resolved, options: options, cachePolicy: .persistent)
        } catch {
            // An invalid persistent specialization fails with nilError: drop it once and rebuild.
            guard isUnusableCacheError(error) else { throw error }
            return try await rebuild(resolved)
        }
    }

    /// Drops a persistent specialization before compiling it again from the verified asset.
    /// The caller must release its AIModel and InferenceFunction references before this call.
    static func rebuild(_ url: URL, bookmark: Data? = nil) async throws -> AIModel {
        let resolved = url.resolvingSymlinksInPath()
        // Core AI's bookmark is an opaque cache identifier, not a file-system bookmark.
        if let bookmark {
            try AIModelCache.deleteEntry(referencedBy: bookmark)
        } else {
            try AIModelCache.default.deleteEntries(for: resolved)
        }
        return try await AIModel.specialize(contentsOf: resolved, options: options, cachePolicy: .persistent)
    }

    /// MPSGraph reports an unusable cached model through this otherwise unhelpful error.
    static func isUnusableCacheError(_ error: Error) -> Bool {
        let description = String(reflecting: error)
        return description.contains("GenericObjCError") || description.contains("nilError")
    }

    /// Rebuilds once when a cached model fails to load at inference time, then retries the same call.
    static func withCacheRecovery<T: ~Copyable>(rebuild: () async throws -> Void,
                                                operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard isUnusableCacheError(error) else { throw error }
            try await rebuild()
            return try await operation()
        }
    }

    static func descriptor(_ value: InferenceValue.Descriptor?, _ name: String) throws -> NDArrayDescriptor {
        guard case .ndArray(let descriptor)? = value else { throw VoxError.engine("\(name) is not an array") }
        return descriptor
    }

    static func write(_ array: inout NDArray, _ body: (UnsafeMutablePointer<Float16>, [Int], [Int]) -> Void) {
        let view = array.mutableView(as: Float16.self)
        view.withUnsafeMutablePointer { pointer, shape, strides in
            body(pointer, (0..<shape.count).map { shape[$0] }, (0..<strides.count).map { strides[$0] })
        }
    }

    static func read<R>(_ array: NDArray, _ body: (UnsafePointer<Float16>, [Int], [Int]) -> R) -> R {
        array.rawView().withUnsafeBytes { raw, shape, strides in
            body(raw.assumingMemoryBound(to: Float16.self),
                 (0..<shape.count).map { shape[$0] }, (0..<strides.count).map { strides[$0] })
        }
    }

    /// Visits the largest contiguous runs of a strided array in row-major order.
    static func forEachBlock(_ shape: [Int], _ strides: [Int], _ body: (Int, Int, Int) -> Void) {
        var axis = shape.count, block = 1
        while axis > 0 {
            let next = axis - 1
            if shape[next] != 1 && strides[next] != block { break }
            block *= shape[next]
            axis = next
        }
        let outer = Array(shape.prefix(axis)), outerStrides = Array(strides.prefix(axis))
        let count = outer.reduce(1, *)
        var index = [Int](repeating: 0, count: outer.count), offset = 0
        for linear in 0..<count {
            body(linear * block, offset, block)
            var position = outer.count - 1
            while position >= 0 {
                index[position] += 1
                offset += outerStrides[position]
                if index[position] < outer[position] { break }
                offset -= outerStrides[position] * outer[position]
                index[position] = 0
                position -= 1
            }
        }
    }

    /// A new input of the function's declared shape filled from row-major `values`.
    static func input(_ function: InferenceFunction, _ key: String, _ values: [Float16]) throws -> NDArray {
        var array = NDArray(descriptor: try descriptor(function.descriptor.inputDescriptor(of: key), key))
        var matches = false
        write(&array) { pointer, shape, strides in
            matches = shape.reduce(1, *) == values.count
            guard matches else { return }
            values.withUnsafeBufferPointer { source in
                forEachBlock(shape, strides) { linear, offset, count in
                    pointer.advanced(by: offset).update(from: source.baseAddress!.advanced(by: linear), count: count)
                }
            }
        }
        guard matches else { throw VoxError.engine("wrong element count for \(key)") }
        return array
    }

    static func flatten(_ array: NDArray) -> [Float16] {
        read(array) { pointer, shape, strides in
            var flat = [Float16](repeating: 0, count: shape.reduce(1, *))
            flat.withUnsafeMutableBufferPointer { target in
                forEachBlock(shape, strides) { linear, offset, count in
                    target.baseAddress!.advanced(by: linear).update(from: pointer.advanced(by: offset), count: count)
                }
            }
            return flat
        }
    }
}

/// One `.aimodelc` asset whose functions are loaded on first use.
@available(macOS 27.0, *)
final class VoxAsset {
    let url: URL
    private var model: AIModel?
    private var functions: [String: InferenceFunction] = [:]
    private(set) var seconds = 0.0

    init(url: URL) async throws {
        self.url = url
        model = try await VoxCoreAI.load(url)
    }

    private func storedFunction(_ name: String) throws -> InferenceFunction {
        if let function = functions[name] { return function }
        guard let model else { throw VoxError.engine("model is being rebuilt") }
        guard let function = try model.loadFunction(named: name) else { throw VoxError.engine("missing function \(name)") }
        functions[name] = function
        return function
    }

    private func rebuildModel() async throws {
        let bookmark = model?.bookmarkData
        functions.removeAll()
        model = nil
        model = try await VoxCoreAI.rebuild(url, bookmark: bookmark)
    }

    /// Loading a function can be the first operation that touches the compiled model.
    func function(_ name: String) async throws -> InferenceFunction {
        try await VoxCoreAI.withCacheRecovery(rebuild: rebuildModel, operation: {
            try storedFunction(name)
        })
    }

    /// Executes a function, rebuilding this asset's persistent cache once if MPSGraph cannot load it.
    func execute(_ name: String, inputs: [String: NDArray], output: String = "features") async throws -> NDArray {
        try await VoxCoreAI.withCacheRecovery(rebuild: rebuildModel, operation: {
            let function = try await function(name)
            let started = ContinuousClock.now
            var outputs = try await function.run(inputs: inputs)
            seconds += (ContinuousClock.now - started).voxSeconds
            guard let result = outputs.remove(output)?.ndArray else { throw VoxError.engine("missing \(output) output") }
            return result
        })
    }

    /// Runs a stateless function on row-major float16 inputs; returns its row-major `output`.
    func run(_ name: String, _ values: [String: [Float16]], output: String = "features") async throws -> [Float16] {
        let function = try await function(name)
        var inputs: [String: NDArray] = [:]
        for (key, value) in values { inputs[key] = try VoxCoreAI.input(function, key, value) }
        return VoxCoreAI.flatten(try await execute(name, inputs: inputs, output: output))
    }

    /// A causal stage: grows its key/value cache here and returns only the new hidden rows.
    final class Cached {
        struct Function { let name: String; let capacity: Int; let width: Int }
        let asset: VoxAsset
        let hidden: Int
        let channels: Int
        let functions: [Function]
        private var cache: NDArray?
        private var capacity = 0
        private(set) var position = 0

        init(asset: VoxAsset, hidden: Int, channels: Int, functions: [Function]) {
            self.asset = asset; self.hidden = hidden; self.channels = channels; self.functions = functions
        }

        func reset() { cache = nil; capacity = 0; position = 0 }

        private func grow(to next: Int, function: InferenceFunction) throws {
            if next == capacity { return }
            var grown = NDArray(descriptor: try VoxCoreAI.descriptor(function.descriptor.inputDescriptor(of: "cache"), "cache"))
            let filled = position, channels = channels
            VoxCoreAI.write(&grown) { target, shape, ts in
                VoxCoreAI.forEachBlock(shape, ts) { _, offset, count in memset(target.advanced(by: offset), 0, count * 2) }
                if let old = cache {
                    VoxCoreAI.read(old) { source, _, ss in
                        for channel in 0..<channels {
                            for index in 0..<filled { target[channel * ts[1] + index * ts[3]] = source[channel * ss[1] + index * ss[3]] }
                        }
                    }
                }
            }
            cache = grown
            capacity = next
        }

        /// Runs `name` on `values` whose first `count` columns are real; returns hidden × count row-major.
        func run(_ name: String, count: Int, values: [String: [Float16]]) async throws -> [Float16] {
            guard let spec = functions.first(where: { $0.name == name }) else { throw VoxError.engine("unknown function \(name)") }
            let function = try await asset.function(name)
            try grow(to: spec.capacity, function: function)
            var inputs: [String: NDArray] = [:]
            for (key, value) in values { inputs[key] = try VoxCoreAI.input(function, key, value) }
            var mask = NDArray(descriptor: try VoxCoreAI.descriptor(function.descriptor.inputDescriptor(of: "mask"), "mask"))
            let filled = position, capacity = capacity
            VoxCoreAI.write(&mask) { target, shape, strides in
                VoxCoreAI.forEachBlock(shape, strides) { _, offset, count in
                    target.advanced(by: offset).update(repeating: Float16(-30000), count: count)
                }
                for row in 0..<spec.width {
                    let offset = row * strides[2]
                    for index in 0..<filled { target[offset + index * strides[3]] = 0 }
                    for index in 0..<min(row + 1, count) { target[offset + (capacity + index) * strides[3]] = 0 }
                }
            }
            inputs["mask"] = mask
            inputs["cache"] = cache
            let result = try await asset.execute(name, inputs: inputs)
            // Drop the input's reference before writing the cache's new rows.
            inputs["cache"] = nil
            var rows = [Float16](repeating: 0, count: hidden * count)
            let hidden = hidden, channels = channels
            VoxCoreAI.read(result) { source, _, ss in
                for channel in 0..<hidden {
                    for index in 0..<count { rows[channel * count + index] = source[channel * ss[1] + index * ss[3]] }
                }
                VoxCoreAI.write(&cache!) { target, _, ts in
                    for channel in 0..<channels {
                        for index in 0..<count {
                            target[channel * ts[1] + (filled + index) * ts[3]] = source[(hidden + channel) * ss[1] + index * ss[3]]
                        }
                    }
                }
            }
            position += count
            return rows
        }
    }
}

extension Duration {
    var voxSeconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
#endif
