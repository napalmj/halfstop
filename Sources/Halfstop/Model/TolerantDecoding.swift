import Foundation

/// Counts what was dropped while decoding a file, so the loader can keep a copy of the original
/// before the next save overwrites it. Attach one with `decoder.userInfo[.decodeReport]`.
final class DecodeReport {
    private(set) var dropped = 0
    func noteDropped() { dropped += 1 }
}

extension CodingUserInfoKey {
    static let decodeReport = CodingUserInfoKey(rawValue: "halfstop.decodeReport")!
}

extension JSONDecoder {
    /// A decoder that records dropped values in `report`.
    static func reporting(into report: DecodeReport) -> JSONDecoder {
        let d = JSONDecoder()
        d.userInfo[.decodeReport] = report
        return d
    }
}

/// Decodes one value of any shape, so a bad array element can be stepped over.
private struct Skip: Decodable {
    init(from decoder: Decoder) throws {}
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Field-by-field decoding that never throws for a bad field: a missing field takes its
/// default (older and newer files keep loading), a malformed one also takes its default and is
/// counted, and arrays and dictionaries keep every element that decodes.
struct TolerantContainer<K: CodingKey> {
    let c: KeyedDecodingContainer<K>
    private let report: DecodeReport?

    init(_ decoder: Decoder, keyedBy: K.Type) throws {
        c = try decoder.container(keyedBy: K.self)
        report = decoder.userInfo[.decodeReport] as? DecodeReport
    }

    func noteDropped() { report?.noteDropped() }

    /// The field's value; `fallback` when it's missing, null or malformed.
    func value<T: Decodable>(_ key: K, _ fallback: @autoclosure () -> T) -> T {
        optional(key) ?? fallback()
    }

    /// The field's value; nil when it's missing, null or malformed.
    func optional<T: Decodable>(_ key: K, as type: T.Type = T.self) -> T? {
        guard c.contains(key) else { return nil }
        do {
            return try c.decodeIfPresent(T.self, forKey: key)
        } catch {
            noteDropped()
            return nil
        }
    }

    /// A field the value can't exist without (a folder's path, say): throws, so the enclosing
    /// element is dropped and counted by the array that holds it.
    func required<T: Decodable>(_ key: K, as type: T.Type = T.self) throws -> T {
        try c.decode(T.self, forKey: key)
    }

    /// Every element that decodes; malformed ones are skipped. Nil when the field is missing.
    func array<T: Decodable>(_ key: K, of type: T.Type = T.self) -> [T]? {
        guard c.contains(key), (try? c.decodeNil(forKey: key)) == false else { return nil }
        guard var u = try? c.nestedUnkeyedContainer(forKey: key) else {
            noteDropped()
            return nil
        }
        var out: [T] = []
        out.reserveCapacity(u.count ?? 0)
        while !u.isAtEnd {
            if let v = try? u.decode(T.self) {
                out.append(v)
            } else {
                noteDropped()
                // A failed decode doesn't always advance the container; step over the element.
                guard (try? u.decode(Skip.self)) != nil else { break }
            }
        }
        return out
    }

    func array<T: Decodable>(_ key: K, default fallback: [T]) -> [T] {
        array(key, of: T.self) ?? fallback
    }

    /// Every entry that decodes; malformed ones are skipped. Nil when the field is missing.
    func dictionary<T: Decodable>(_ key: K, of type: T.Type = T.self) -> [String: T]? {
        guard c.contains(key), (try? c.decodeNil(forKey: key)) == false else { return nil }
        guard let nested = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: key) else {
            noteDropped()
            return nil
        }
        var out: [String: T] = [:]
        for k in nested.allKeys {
            if let v = try? nested.decode(T.self, forKey: k) { out[k.stringValue] = v } else { noteDropped() }
        }
        return out
    }
}

/// Decodes a top-level JSON array element by element (for files that are just a list).
struct TolerantList<T: Decodable>: Decodable {
    var items: [T] = []

    init(from decoder: Decoder) throws {
        let report = decoder.userInfo[.decodeReport] as? DecodeReport
        var u = try decoder.unkeyedContainer()
        while !u.isAtEnd {
            if let v = try? u.decode(T.self) {
                items.append(v)
            } else {
                report?.noteDropped()
                guard (try? u.decode(Skip.self)) != nil else { break }
            }
        }
    }
}

enum FileBackup {
    /// Copies a file that lost data while loading to `<name>.partial-<hash>.<ext>` next to it,
    /// once per distinct content, so the original survives the next save.
    @discardableResult
    static func keepPartiallyLoaded(_ url: URL, data: Data) -> URL? {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in data { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let dest = url.deletingLastPathComponent()
            .appendingPathComponent("\(stem).partial-\(String(h, radix: 36))" + (ext.isEmpty ? "" : ".\(ext)"))
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        do {
            try data.write(to: dest, options: .withoutOverwriting)
            return dest
        } catch {
            return nil
        }
    }
}
