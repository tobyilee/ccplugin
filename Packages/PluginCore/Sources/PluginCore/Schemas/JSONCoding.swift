import Foundation

/// PluginCore 의 모든 schema 가 공유하는 JSON encode/decode 전략.
///
/// - ISO8601 with fractional seconds (Claude Code 가 발행하는 모든 timestamp 형식)
/// - 키 정렬 + pretty-print (라운드트립 비교 안정성)
public enum JSONCoding {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = iso8601WithFractional.date(from: raw) { return date }
            if let date = iso8601Plain.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported ISO8601 date \(raw)"
            )
        }
        return decoder
    }

    public static func encoder(prettyPrinted: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = [.sortedKeys]
        if prettyPrinted { formatting.insert(.prettyPrinted) }
        encoder.outputFormatting = formatting
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601WithFractional.string(from: date))
        }
        return encoder
    }

    /// `ISO8601DateFormatter` 는 macOS 10.12+ 부터 thread-safe (Apple Foundation docs)
    /// 이지만 Sendable 마킹 안 됨 → 명시적 nonisolated(unsafe).
    nonisolated(unsafe) static let iso8601WithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
