import Foundation

/// Reports one failing asset. An ANE missing-file error can justify a precise
/// repair on a later explicit retry; an opaque delegate error cannot.
struct VoxAssetFailure: LocalizedError {
    var asset: String
    var cause: Error
    var cachedFunctionLoad = false

    var errorDescription: String? {
        let underlying = cause as NSError
        return "The Neural Engine could not run \(asset) (\(underlying.domain) \(underlying.code))."
    }

    var missingSpecialization: Bool {
        let error = cause as NSError
        // MPSGraph can hide an ANE model-load failure behind this opaque error.
        // Offer a single explicit repair only for function loading from a cache hit.
        if cachedFunctionLoad && error.domain == "Foundation._GenericObjCError" && error.code == 0 {
            return true
        }
        var next: NSError? = cause as NSError
        for _ in 0..<8 {
            guard let error = next else { return false }
            if error.domain == "com.apple.appleneuralengine", error.code == 16 { return true }
            next = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}

#if canImport(CoreAI)
import CoreAI

// Core AI stages for the VoxCPM2 bundle, ported from tinkerbox-ane's Swift host
// (host.swift and cached.swift, Apache-2.0). Only public Core AI API is used: the first load
// on a Mac compiles each asset for its Neural Engine (minutes), later loads reuse the cache.

@available(macOS 27.0, *)
enum VoxCoreAI {
    static let options: SpecializationOptions = {
        var options = SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
        options.expectFrequentReshapes = false
        return options
    }()

    /// The sandbox-inheriting worker has no app-group signing entitlement of its own.
    /// ANE rejects coalescing newly compiled assets into a group cache for this child.
    /// Use its own default cache with the explicit non-storage-pressure purge policy below.
    static let cache: AIModelCache = .default

    /// Never purge under storage pressure. `.persistent` and the default policy both include
    /// `.storagePressure`, which turns "disk almost full" into "specializations disappear".
    /// Only the source asset changing (a model update) justifies dropping an entry.
    static let cachePolicy = AIModelCache.Policy(purgeConditions: [.sourceAssetChangedOrDeleted])

    /// This Mac's Neural Engine architecture, as named in bundle file names (for example "h16g").
    static var architecture: String { AIModel.deviceArchitectureName }

    static func load(_ url: URL) async throws -> AIModel {
        // Core AI rejects an asset directory that is itself a symbolic link.
        let resolved = url.resolvingSymlinksInPath()
        probeCacheLookup(resolved)
        do {
            return try await AIModel.specialize(contentsOf: resolved, options: options, cache: cache, cachePolicy: cachePolicy)
        } catch {
            throw VoxAssetFailure(asset: resolved.lastPathComponent, cause: error)
        }
    }

    /// Called by an exclusive worker before it has loaded any model.
    static func repair(_ asset: String, in folder: URL) throws {
        let manifest = try JSONDecoder().decode(VoxManifest.self, from: Data(contentsOf: folder.appendingPathComponent("model.json")))
        let root = folder.resolvingSymlinksInPath()
        let target = folder.appendingPathComponent(asset).resolvingSymlinksInPath()
        guard manifest.assets.contains(where: { $0.asset == asset }),
              target.deletingLastPathComponent().path == root.path, target.lastPathComponent == asset else {
            throw VoxError.format("unexpected specialization asset")
        }
        // A miss will naturally specialize. Preserve every other asset/options entry.
        do {
            if try cache.model(for: target, options: options) == nil { return }
        } catch {
            // An unreadable entry is the reason this narrowly scoped repair was requested.
            probeLog("vox-cache-repair-lookup-failed", ["asset": asset, "code": (error as NSError).code])
        }
        try cache.deleteEntry(for: target, options: options)
        probeLog("vox-cache-entry-repaired", ["asset": asset])
    }

    /// Proves in the next diagnostics whether a specialization survived between launches:
    /// a hit means the cache kept it, a miss means it was purged (or never durably written).
    static func probeCacheLookup(_ resolved: URL) {
        let hit = (try? cache.model(for: resolved, options: options)) != nil
        probeLog("vox-cache-lookup", ["asset": resolved.lastPathComponent, "present": hit])
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
    private let model: AIModel
    private let asset: String
    private let hadCachedModel: Bool
    private var functions: [String: InferenceFunction] = [:]
    private(set) var seconds = 0.0

    init(url: URL) async throws {
        asset = url.lastPathComponent
        hadCachedModel = (try? VoxCoreAI.cache.model(for: url.resolvingSymlinksInPath(), options: VoxCoreAI.options)) != nil
        model = try await VoxCoreAI.load(url)
    }

    func function(_ name: String) throws -> InferenceFunction {
        if let function = functions[name] { return function }
        do {
            guard let function = try model.loadFunction(named: name) else { throw VoxError.engine("missing function \(name)") }
            functions[name] = function
            return function
        } catch {
            throw VoxAssetFailure(asset: asset, cause: error, cachedFunctionLoad: hadCachedModel)
        }
    }

    private func evaluate(_ function: InferenceFunction, inputs: [String: NDArray], output: String) async throws -> NDArray {
        let started = ContinuousClock.now
        do {
            var outputs = try await function.run(inputs: inputs)
            seconds += (ContinuousClock.now - started).voxSeconds
            guard let result = outputs.remove(output)?.ndArray else { throw VoxError.engine("missing \(output) output") }
            return result
        } catch {
            throw VoxAssetFailure(asset: asset, cause: error)
        }
    }

    /// Runs a stateless function on row-major float16 inputs; returns its row-major output.
    func run(_ name: String, _ values: [String: [Float16]], output: String = "features") async throws -> [Float16] {
        let function = try function(name)
        var inputs: [String: NDArray] = [:]
        for (key, value) in values { inputs[key] = try VoxCoreAI.input(function, key, value) }
        let array = try await evaluate(function, inputs: inputs, output: output)
        return VoxCoreAI.flatten(array)
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
            let function = try asset.function(name)
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
            let result = try await asset.evaluate(function, inputs: inputs, output: "features")
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
