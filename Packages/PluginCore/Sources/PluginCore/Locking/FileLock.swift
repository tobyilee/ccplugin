import Foundation

/// `proper-lockfile` 호환 디렉토리 락.
///
/// Claude Code 의 `~/.claude/settings.json` 에 사용된 `proper-lockfile` 규약과 호환:
/// `<target>.lock/` 디렉토리 mkdir 으로 락 보유, rmdir 로 해제.
/// Swift `flock(2)` 와는 호환 안 됨 — proper-lockfile 이 디렉토리 기반이기 때문.
///
/// PRD §10.4 / R12 spike 결론.
public actor FileLock {

    public enum LockError: Error, Sendable, Equatable {
        case timeout
        case cannotCreateLockDirectory(String)
    }

    public let lockDirURL: URL
    private var heldByMe: Bool = false

    public init(target: URL) {
        // proper-lockfile 의 default lockfilePath = `${file}.lock`.
        self.lockDirURL = target.appendingPathExtension("lock")
    }

    /// 락 획득. 이미 다른 프로세스가 보유하면 polling 으로 대기, deadline 초과 시 throw.
    public func acquire(
        timeout: Duration = .seconds(5),
        pollInterval: Duration = .milliseconds(50)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        let fm = FileManager.default
        while true {
            // race-tolerant: 사전 체크 + 실패 시 retry.
            if !fm.fileExists(atPath: lockDirURL.path) {
                do {
                    try fm.createDirectory(at: lockDirURL, withIntermediateDirectories: false)
                    // proper-lockfile 호환: metadata 파일 (pid/timestamp) 작성.
                    let metadata: [String: Any] = [
                        "pid": ProcessInfo.processInfo.processIdentifier,
                        "timestamp": Date().timeIntervalSince1970,
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: metadata) {
                        try? data.write(to: lockDirURL.appending(path: "metadata.json"))
                    }
                    heldByMe = true
                    return
                } catch {
                    // race lost: 다른 누군가 1µs 전에 mkdir 함. retry.
                }
            }
            if ContinuousClock.now >= deadline {
                throw LockError.timeout
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    /// 보유 락 해제. 보유한 적 없으면 no-op.
    public func release() async {
        guard heldByMe else { return }
        try? FileManager.default.removeItem(at: lockDirURL)
        heldByMe = false
    }

    /// 락 보유 상태에서 클로저 실행. 성공/실패 모두 release 보장.
    public func withLock<T>(_ work: () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let result = try await work()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }

    /// 디버깅/관측용 — 현재 락 보유 여부.
    public var isHeldByMe: Bool { heldByMe }
}
