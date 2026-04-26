import Foundation
import CoreServices

/// macOS FSEventStream 기반 디렉토리 변경 감지.
///
/// PRD §3.3: `~/.claude` 트리 변경을 매니저 UI 에 푸시.
/// `kFSEventStreamCreateFlagIgnoreSelf` 로 매니저 자신의 쓰기로 무한 루프 방지.
///
/// 사용법:
/// ```
/// let watcher = FSEventsWatcher(paths: [ClaudePaths.pluginsDir])
/// watcher.start { changedURLs in
///     // ViewModel reload
/// }
/// // ... 종료 시
/// watcher.stop()
/// ```
public final class FSEventsWatcher: @unchecked Sendable {

    public typealias Callback = @Sendable (Set<URL>) -> Void

    private let paths: [String]
    private let latency: TimeInterval
    private let ignoreSelf: Bool
    private let queue: DispatchQueue
    private var stream: FSEventStreamRef?
    private var contextRetainer: CallbackContext?

    /// - Parameters:
    ///   - ignoreSelf: 기본 true — 매니저 자신이 발행한 쓰기로 무한 루프 방지.
    ///                 같은 프로세스의 쓰기가 callback 을 발생시켜야 하는 테스트 환경에서만 false.
    public init(
        paths: [URL],
        latency: TimeInterval = 0.5,
        ignoreSelf: Bool = true,
        queue: DispatchQueue = DispatchQueue(label: "com.toby.ccplugin.fsevents", qos: .utility)
    ) {
        self.paths = paths.map(\.path)
        self.latency = latency
        self.ignoreSelf = ignoreSelf
        self.queue = queue
    }

    deinit {
        // start() 후 stop() 안 부르면 release.
        if let stream {
            FSEventStreamSetDispatchQueue(stream, nil)
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// Watch 시작. 같은 인스턴스 재시작 시 기존 stream 폐기.
    public func start(onChange: @escaping Callback) {
        stop()  // 안전: 기존 stream 정리

        let context = CallbackContext(onChange: onChange)
        self.contextRetainer = context

        var streamContext = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(context).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        var rawFlags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
        if ignoreSelf {
            rawFlags |= kFSEventStreamCreateFlagIgnoreSelf
        }
        let flags = FSEventStreamCreateFlags(rawFlags)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (_, info, count, paths, _, _) in
                guard let info else { return }
                let context = Unmanaged<CallbackContext>.fromOpaque(info).takeUnretainedValue()
                guard let pathsArray = unsafeBitCast(paths, to: NSArray.self) as? [String] else {
                    return
                }
                let urls = Set(pathsArray.map { URL(fileURLWithPath: $0) })
                if !urls.isEmpty {
                    context.onChange(urls)
                }
                _ = count  // unused but needed for signature
            },
            &streamContext,
            self.paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            self.latency,
            flags
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, nil)
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        self.contextRetainer = nil
    }

    /// FSEventStream callback 의 C 함수 → Swift 클로저 브릿지용 컨테이너.
    private final class CallbackContext: @unchecked Sendable {
        let onChange: Callback
        init(onChange: @escaping Callback) {
            self.onChange = onChange
        }
    }
}
