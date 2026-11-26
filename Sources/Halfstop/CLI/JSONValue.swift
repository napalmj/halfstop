import Foundation

/// A JSON value with exact types (an integer stays an integer, `true` is never the number 1), so the
/// command-line tool's `--json` output is built without `Any` and always prints the same way.
enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Deepest nesting `parse` accepts (the tool's own output needs a handful of levels).
    static let maxDepth = 32

    enum ParseError: Error, Equatable { case invalid, tooDeep }

    /// Parses a complete JSON text (UTF-8), for the self-test reading the tool's output. Nesting is
    /// checked first, on the raw bytes, so a hostile `[[[[…` can't exhaust the parser's stack.
    static func parse(_ data: Data) -> Result<JSONValue, ParseError> {
        guard depth(of: data) <= maxDepth else { return .failure(.tooDeep) }
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let value = JSONValue(any: any) else { return .failure(.invalid) }
        return .success(value)
    }

    /// Bracket depth outside strings (an upper bound of the real depth for valid JSON).
    static func depth(of data: Data) -> Int {
        var depth = 0, deepest = 0, inString = false, escaped = false
        for b in data {
            if inString {
                if escaped { escaped = false } else if b == UInt8(ascii: "\\") { escaped = true } else if b == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch b {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                deepest = max(deepest, depth)
                if deepest > maxDepth { return deepest }
            case UInt8(ascii: "]"), UInt8(ascii: "}"): depth -= 1
            default: break
            }
        }
        return deepest
    }

    init?(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if CFNumberIsFloatType(n) {
                let d = n.doubleValue
                guard d.isFinite else { return nil }
                self = .double(d)
            } else {
                // Integers beyond Int64 come back as floats or decimals; refuse what doesn't fit.
                guard let i = Int(exactly: n.int64Value), NSNumber(value: i) == n else { return nil }
                self = .int(i)
            }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            var out: [JSONValue] = []
            out.reserveCapacity(a.count)
            for x in a {
                guard let v = JSONValue(any: x) else { return nil }
                out.append(v)
            }
            self = .array(out)
        case let o as [String: Any]:
            var out: [String: JSONValue] = [:]
            for (k, x) in o {
                guard let v = JSONValue(any: x) else { return nil }
                out[k] = v
            }
            self = .object(out)
        default:
            return nil
        }
    }

    /// Compact JSON with sorted keys (stable output, stable tests) and the shortest decimal for
    /// each number (0.1, not 0.10000000000000001).
    func encoded() -> Data {
        var out = ""
        write(to: &out)
        return Data(out.utf8)
    }

    private func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d):
            if !d.isFinite { out += "null" } else if d == d.rounded(), abs(d) < 1e15 { out += String(Int(d)) } else { out += "\(d)" }
        case .string(let s): Self.writeString(s, to: &out)
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += "," }
                v.write(to: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            for (i, k) in o.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                Self.writeString(k, to: &out)
                out += ":"
                o[k]!.write(to: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20 || u.value == 0x2028 || u.value == 0x2029:
                out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        out += "\""
    }

    var text: String { String(decoding: encoded(), as: UTF8.self) }

    // Accessors
    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var intValue: Int? { if case .int(let i) = self { return i }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    /// Integers and decimals alike (never booleans).
    var numberValue: Double? {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        default: nil
        }
    }

    /// A number rounded to `places` decimals, for compact output.
    static func number(_ d: Double, places: Int = 4) -> JSONValue {
        guard d.isFinite else { return .null }
        let f = pow(10, Double(places))
        return .double((d * f).rounded() / f)
    }
}

extension JSONValue: ExpressibleByStringInterpolation, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                     ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(stringInterpolation: DefaultStringInterpolation) { self = .string(String(stringInterpolation: stringInterpolation)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
}
