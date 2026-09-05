import Foundation

/// Tolerant helpers over JSONSerialization output. The usage APIs are undocumented,
/// so field types are coerced rather than decoded strictly.
enum JSON {
    static func object(from data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decoding("body is not a JSON object: \(String(decoding: data.prefix(120), as: UTF8.self))")
        }
        return object
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    /// Accepts epoch seconds, epoch milliseconds, or an ISO-8601 string.
    static func date(_ value: Any?) -> Date? {
        if let seconds = double(value) {
            return Date(timeIntervalSince1970: seconds > 1e11 ? seconds / 1000 : seconds)
        }
        if let text = value as? String {
            for formatter in isoFormatters {
                if let date = formatter.date(from: text) { return date }
            }
        }
        return nil
    }

    private static let isoFormatters: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [fractional, plain]
    }()
}
