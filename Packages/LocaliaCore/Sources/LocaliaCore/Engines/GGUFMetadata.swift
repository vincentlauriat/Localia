import Foundation

/// Reads the trained context length (`<general.architecture>.context_length`) from a GGUF file header,
/// without loading the model. Only the metadata key/value section is read; arrays are skipped.
public enum GGUFMetadata {
    private enum ValueType: UInt32 {
        case uint8 = 0, int8, uint16, int16, uint32, int32, float32, bool, string, array, uint64, int64, float64
        var fixedSize: Int? {
            switch self {
            case .uint8, .int8, .bool: 1
            case .uint16, .int16: 2
            case .uint32, .int32, .float32: 4
            case .uint64, .int64, .float64: 8
            case .string, .array: nil
            }
        }
    }

    private struct Reader {
        let handle: FileHandle
        mutating func bytes(_ n: Int) throws -> Data {
            guard n >= 0, let d = try handle.read(upToCount: n), d.count == n else { throw CocoaError(.fileReadCorruptFile) }
            return d
        }
        mutating func u32() throws -> UInt32 { try bytes(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian }
        mutating func u64() throws -> UInt64 { try bytes(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian }
        mutating func skip(_ n: UInt64) throws {
            let off = try handle.offset()
            try handle.seek(toOffset: off + n)
        }
        mutating func string() throws -> String {
            let n = try u64()
            guard n <= 1 << 20 else { throw CocoaError(.fileReadCorruptFile) }
            return String(decoding: try bytes(Int(n)), as: UTF8.self)
        }
    }

    /// nil when the file is not a GGUF (v2 or v3) or carries no context length.
    public static func contextLength(of url: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var r = Reader(handle: handle)
        do {
            guard try r.bytes(4) == Data("GGUF".utf8) else { return nil }
            let version = try r.u32()
            guard version >= 2 else { return nil }
            _ = try r.u64()                       // tensor count
            let kvCount = try r.u64()
            guard kvCount <= 100_000 else { return nil }
            var arch: String?
            var lengths: [String: Int] = [:]
            for _ in 0..<kvCount {
                let key = try r.string()
                guard let type = ValueType(rawValue: try r.u32()) else { return nil }
                switch type {
                case .string:
                    let s = try r.string()
                    if key == "general.architecture" { arch = s }
                case .array:
                    guard let inner = ValueType(rawValue: try r.u32()) else { return nil }
                    let n = try r.u64()
                    if let size = inner.fixedSize {
                        try r.skip(n * UInt64(size))
                    } else if inner == .string {
                        for _ in 0..<n { try r.skip(try r.u64()) }
                    } else {
                        return nil                // nested arrays: not used by llama.cpp metadata
                    }
                case .uint32, .int32:
                    let v = try r.u32()
                    if key.hasSuffix(".context_length") { lengths[key] = Int(type == .int32 ? Int(Int32(bitPattern: v)) : Int(v)) }
                case .uint64, .int64:
                    let v = try r.u64()
                    if key.hasSuffix(".context_length"), v <= UInt64(Int.max) { lengths[key] = Int(v) }
                default:
                    try r.skip(UInt64(type.fixedSize ?? 0))
                }
                if let arch, let n = lengths["\(arch).context_length"], n > 0 { return n }
            }
            return nil
        } catch {
            return nil
        }
    }
}
