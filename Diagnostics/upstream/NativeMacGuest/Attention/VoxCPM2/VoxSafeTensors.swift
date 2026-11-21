import Foundation

/// Errors from loading or running the VoxCPM2 voice model.
enum VoxError: LocalizedError, Equatable {
    case format(String)
    case unsupported(String)
    case context(String)
    case audio(String)
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .format(let detail): "The voice model files are damaged or incomplete (\(detail))."
        case .unsupported(let detail): "This voice model does not run on this Mac (\(detail))."
        case .context(let detail): detail
        case .audio(let detail): "The voice model produced unusable audio (\(detail))."
        case .engine(let detail): "The Neural Engine could not run the voice model (\(detail))."
        }
    }
}

/// A memory-mapped safetensors file: an 8-byte header length, a JSON header, then raw
/// little-endian tensors. Pointers stay valid for the object's lifetime; pages load on use.
final class VoxSafeTensors {
    struct Entry {
        let dtype: String
        let shape: [Int]
        let offset: Int
        let bytes: Int
        var count: Int { shape.reduce(1, *) }
    }

    let url: URL
    let entries: [String: Entry]
    private let mapping: UnsafeMutableRawPointer
    private let length: Int
    private let base: Int

    init(url: URL) throws {
        self.url = url
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw VoxError.format("cannot open \(url.lastPathComponent)") }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_size > 8 else { throw VoxError.format("\(url.lastPathComponent) is empty") }
        length = Int(status.st_size)
        guard let pointer = mmap(nil, length, PROT_READ, MAP_PRIVATE, descriptor, 0), pointer != MAP_FAILED else {
            throw VoxError.format("cannot map \(url.lastPathComponent)")
        }
        mapping = pointer
        var parsed: [String: Entry] = [:]
        var tensorBase = 0
        do {
            let headerSize = Int(UInt64(littleEndian: pointer.loadUnaligned(as: UInt64.self)))
            guard headerSize > 0, headerSize <= length - 8 else { throw VoxError.format("bad header in \(url.lastPathComponent)") }
            let header = Data(bytes: pointer + 8, count: headerSize)
            guard let object = try JSONSerialization.jsonObject(with: header) as? [String: Any] else {
                throw VoxError.format("bad header in \(url.lastPathComponent)")
            }
            tensorBase = 8 + headerSize
            for (name, value) in object where name != "__metadata__" {
                guard let info = value as? [String: Any], let dtype = info["dtype"] as? String,
                      let shape = info["shape"] as? [Int], let offsets = info["data_offsets"] as? [Int], offsets.count == 2,
                      offsets[0] >= 0, offsets[1] >= offsets[0], tensorBase + offsets[1] <= length else {
                    throw VoxError.format("bad tensor \(name) in \(url.lastPathComponent)")
                }
                let entry = Entry(dtype: dtype, shape: shape, offset: offsets[0], bytes: offsets[1] - offsets[0])
                let width = ["F32": 4, "F16": 2, "BF16": 2, "I32": 4][dtype] ?? 0
                guard width > 0, entry.count * width == entry.bytes else {
                    throw VoxError.format("tensor \(name) has an unexpected size")
                }
                parsed[name] = entry
            }
        } catch {
            munmap(pointer, length)
            throw error
        }
        entries = parsed
        base = tensorBase
    }

    deinit { munmap(mapping, length) }

    func entry(_ name: String, dtype: String, shape: [Int]? = nil) throws -> Entry {
        guard let entry = entries[name] else { throw VoxError.format("missing tensor \(name)") }
        guard entry.dtype == dtype else { throw VoxError.format("\(name) is \(entry.dtype), expected \(dtype)") }
        if let shape, shape != entry.shape { throw VoxError.format("\(name) has shape \(entry.shape), expected \(shape)") }
        return entry
    }

    func raw(_ entry: Entry) -> UnsafeRawPointer { UnsafeRawPointer(mapping + base + entry.offset) }

    /// A float32 tensor, read in place when aligned.
    func f32(_ name: String, shape: [Int]? = nil) throws -> VoxWeights {
        let entry = try entry(name, dtype: "F32", shape: shape)
        let pointer = raw(entry)
        if Int(bitPattern: pointer) % MemoryLayout<Float>.alignment == 0 {
            return VoxWeights(pointer: pointer.assumingMemoryBound(to: Float.self), count: entry.count, owner: self)
        }
        var copy = [Float](repeating: 0, count: entry.count)
        copy.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: pointer, count: entry.bytes)) }
        return VoxWeights(copy)
    }

    /// A float16 tensor widened to float32.
    func widened(_ name: String, shape: [Int]? = nil) throws -> [Float] {
        let entry = try entry(name, dtype: "F16", shape: shape)
        let pointer = raw(entry)
        var result = [Float](repeating: 0, count: entry.count)
        result.withUnsafeMutableBufferPointer { target in
            for index in 0..<entry.count {
                target[index] = Float(pointer.loadUnaligned(fromByteOffset: index * 2, as: Float16.self))
            }
        }
        return result
    }

    func int32(_ name: String) throws -> [Int32] {
        let entry = try entry(name, dtype: "I32")
        let pointer = raw(entry)
        return (0..<entry.count).map { pointer.loadUnaligned(fromByteOffset: $0 * 4, as: Int32.self) }
    }
}

/// Float32 weights either mapped from a file (kept alive by `owner`) or owned in memory.
struct VoxWeights {
    let pointer: UnsafePointer<Float>
    let count: Int
    private let owner: AnyObject?
    private let storage: VoxStorage?

    init(pointer: UnsafePointer<Float>, count: Int, owner: AnyObject) {
        self.pointer = pointer
        self.count = count
        self.owner = owner
        storage = nil
    }

    init(_ values: [Float]) {
        let storage = VoxStorage(values)
        self.storage = storage
        pointer = UnsafePointer(storage.pointer)
        count = values.count
        owner = nil
    }

    subscript(index: Int) -> Float { pointer[index] }
}

final class VoxStorage {
    let pointer: UnsafeMutablePointer<Float>
    init(_ values: [Float]) {
        pointer = .allocate(capacity: max(1, values.count))
        values.withUnsafeBufferPointer { source in
            if let address = source.baseAddress { pointer.update(from: address, count: source.count) }
        }
    }
    deinit { pointer.deallocate() }
}
