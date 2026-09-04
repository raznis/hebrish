import Foundation

/// On-disk format for `Resources/lexicon.bin`.
///
/// Deliberately dumb and self-describing rather than clever: a magic number, a
/// version, then length-prefixed records. Loading 335k entries costs well under
/// a second, which is fine for a launch-once background agent, and the format
/// stays debuggable.
///
///     "LFXL" u32(version)
///     for each script in [latin, hebrew]:
///         u32 wordCount    ; wordCount  x { u8 byteLen, utf8 bytes, f64 logProb }
///         u32 uniCount     ; uniCount   x { u8 byteLen, utf8 bytes, u32 count }
///         u32 biCount      ; biCount    x { u8 byteLen, utf8 bytes, u32 count }
///         u32 triCount     ; triCount   x { u8 byteLen, utf8 bytes, u32 count }
///     f64 unigramWeight
public enum LexiconFormat {

    public static let magic: [UInt8] = Array("LFXL".utf8)
    public static let version: UInt32 = 1

    public enum Error: Swift.Error, CustomStringConvertible {
        case badMagic
        case unsupportedVersion(UInt32)
        case truncated(at: Int)
        case badUTF8(at: Int)

        public var description: String {
            switch self {
            case .badMagic: return "Not a Hebrish lexicon (bad magic)."
            case .unsupportedVersion(let v): return "Lexicon version \(v) is not supported."
            case .truncated(let o): return "Lexicon truncated at byte \(o)."
            case .badUTF8(let o): return "Lexicon contains invalid UTF-8 at byte \(o)."
            }
        }
    }

    // MARK: writing

    public static func encode(_ lexicon: Lexicon) -> Data {
        var writer = ByteWriter()
        writer.bytes(magic)
        writer.u32(version)
        for script in [Script.latin, Script.hebrew] {
            let model = lexicon.model(for: script)
            writer.stringTable(model.unigrams) { $0.f64($1) }
            writer.stringTable(model.ngram.unigrams) { $0.u32($1) }
            writer.stringTable(model.ngram.bigrams) { $0.u32($1) }
            writer.stringTable(model.ngram.trigrams) { $0.u32($1) }
        }
        writer.f64(lexicon.unigramWeight)
        return writer.data
    }

    // MARK: reading

    public static func decode(_ data: Data) throws -> Lexicon {
        var reader = ByteReader(data)
        guard try reader.bytes(4) == magic else { throw Error.badMagic }
        let v = try reader.u32()
        guard v == version else { throw Error.unsupportedVersion(v) }

        var models: [Script: Lexicon.Model] = [:]
        for script in [Script.latin, Script.hebrew] {
            let words: [String: Double] = try reader.stringTable { try $0.f64() }
            let uni: [String: UInt32] = try reader.stringTable { try $0.u32() }
            let bi: [String: UInt32] = try reader.stringTable { try $0.u32() }
            let tri: [String: UInt32] = try reader.stringTable { try $0.u32() }
            models[script] = Lexicon.Model(
                unigrams: words,
                ngram: CharNGram(unigrams: uni, bigrams: bi, trigrams: tri))
        }
        let weight = try reader.f64()
        return Lexicon(latin: models[.latin]!, hebrew: models[.hebrew]!, unigramWeight: weight)
    }

    /// Resolve where the lexicon lives: inside the .app when bundled, an
    /// explicit override for development, or the repo checkout.
    public static func defaultURL(bundleResource: URL? = nil) -> URL? {
        if let override = ProcessInfo.processInfo.environment["LAYOUTFIX_LEXICON"] {
            return URL(fileURLWithPath: override)
        }
        if let bundled = bundleResource, FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/lexicon.bin")
        if FileManager.default.fileExists(atPath: cwd.path) { return cwd }
        return nil
    }

    public static func load(from url: URL) throws -> Lexicon {
        try decode(Data(contentsOf: url, options: .mappedIfSafe))
    }
}

// MARK: - Minimal byte plumbing

struct ByteWriter {
    var data = Data()

    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }

    mutating func u32(_ v: UInt32) {
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func f64(_ v: Double) {
        withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    /// Length-prefixed key/value table. Keys are sorted so the output is
    /// byte-for-byte reproducible across runs.
    mutating func stringTable<V>(_ table: [String: V],
                                 _ writeValue: (inout ByteWriter, V) -> Void) {
        var records: [(key: [UInt8], value: V)] = []
        records.reserveCapacity(table.count)
        for (key, value) in table {
            let utf8 = Array(key.utf8)
            // Keys are words and n-grams; anything longer is corrupt input.
            guard !utf8.isEmpty, utf8.count <= 255 else { continue }
            records.append((utf8, value))
        }
        records.sort { lhs, rhs in
            lhs.key.lexicographicallyPrecedes(rhs.key)
        }
        u32(UInt32(records.count))
        for record in records {
            data.append(UInt8(record.key.count))
            data.append(contentsOf: record.key)
            writeValue(&self, record.value)
        }
    }
}

struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func bytes(_ n: Int) throws -> [UInt8] {
        guard offset + n <= data.endIndex else { throw LexiconFormat.Error.truncated(at: offset) }
        defer { offset += n }
        return [UInt8](data[offset..<(offset + n)])
    }

    mutating func u8() throws -> UInt8 {
        guard offset < data.endIndex else { throw LexiconFormat.Error.truncated(at: offset) }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func u32() throws -> UInt32 {
        let raw = try bytes(4)
        return raw.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }

    mutating func f64() throws -> Double {
        let raw = try bytes(8)
        let bits = raw.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        return Double(bitPattern: bits)
    }

    mutating func stringTable<V>(_ readValue: (inout ByteReader) throws -> V) throws -> [String: V] {
        let count = Int(try u32())
        var out = [String: V](minimumCapacity: count)
        for _ in 0..<count {
            let length = Int(try u8())
            let keyBytes = try bytes(length)
            guard let key = String(bytes: keyBytes, encoding: .utf8) else {
                throw LexiconFormat.Error.badUTF8(at: offset)
            }
            out[key] = try readValue(&self)
        }
        return out
    }
}
