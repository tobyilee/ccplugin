import Foundation

/// 테스트 공유 헬퍼.

enum TestFixtureError: Error {
    case notFound(String)
}

func loadFixture(_ name: String) throws -> Data {
    // Fixtures 디렉토리 안에서 파일 검색.
    // - 기존 테스트가 `forResource: name, withExtension: nil` 으로 호출하는 경우 (이름에 확장자 포함)
    // - 신규 테스트가 `forResource: name, withExtension: "json"` 으로 호출하는 경우
    // 모두 처리하기 위해 우선 그대로, 실패 시 .json fallback.
    if let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") {
        return try Data(contentsOf: url)
    }
    if name.hasSuffix(".json") {
        let stem = String(name.dropLast(".json".count))
        if let url = Bundle.module.url(forResource: stem, withExtension: "json", subdirectory: "Fixtures") {
            return try Data(contentsOf: url)
        }
    }
    throw TestFixtureError.notFound(name)
}

enum JSONTestHelpers {
    /// 두 JSON 객체 의미적 동등성. Dict 키 순서 무시, Array 순서 의미 보존.
    static func equalIgnoringFormatting(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case let (a as [String: Any], b as [String: Any]):
            guard a.keys.sorted() == b.keys.sorted() else { return false }
            return a.allSatisfy { key, value in
                guard let other = b[key] else { return false }
                return equalIgnoringFormatting(value, other)
            }
        case let (a as [Any], b as [Any]):
            guard a.count == b.count else { return false }
            return zip(a, b).allSatisfy(equalIgnoringFormatting)
        case let (a as String, b as String):
            return a == b
        case let (a as NSNumber, b as NSNumber):
            return a == b
        case (is NSNull, is NSNull):
            return true
        default:
            return false
        }
    }
}
