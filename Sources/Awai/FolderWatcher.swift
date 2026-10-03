import CoreServices
import Foundation

/// vault のフォルダ全体を FSEvents で見張り、変わったファイルのパスをまとめて知らせる。
/// AI エージェントや git が裏でノートを書き換えても、Awai を前面に出したまま反映するために使う。
/// 保存のたびに届く細かい通知は、最後の通知から `delay` 待ってから1回にまとめる
@MainActor
final class FolderWatcher {
    struct Change {
        var paths: Set<String> = []
        /// 作成・削除・名前の変更があったパス（ファイル一覧の作り直しを判断する）
        var movedPaths: Set<String> = []
        /// FSEvents が通知を取りこぼしたので、すべて調べ直す
        var needsFullScan = false
    }

    private var stream: FSEventStreamRef?
    private var pending = Change()
    private var flushTask: Task<Void, Never>?
    private let delay: Duration
    private let onChange: (Change) -> Void

    init?(root: URL, delay: Duration = .milliseconds(200), onChange: @escaping (Change) -> Void) {
        self.delay = delay
        self.onChange = onChange
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil, Self.callback, &context, [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
    }

    /// vault を閉じるとき。止めずに捨てると、解放したあとの自分にコールバックが届く
    func stop() {
        flushTask?.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let address = UInt(bitPattern: info)
        let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        let flags = Array(UnsafeBufferPointer(start: flags, count: count))
        // FSEventStreamSetDispatchQueue(.main) で登録しているので、メインスレッドで呼ばれる
        MainActor.assumeIsolated {
            guard let info = UnsafeRawPointer(bitPattern: address) else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().receive(paths: paths, flags: flags)
        }
    }

    private func receive(paths: [String], flags: [FSEventStreamEventFlags]) {
        let moved = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed
        )
        let dropped = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
        )
        for (path, flag) in zip(paths, flags) {
            pending.paths.insert(path)
            if flag & moved != 0 { pending.movedPaths.insert(path) }
            if flag & dropped != 0 { pending.needsFullScan = true }
        }
        flushTask?.cancel()
        flushTask = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            let change = pending
            pending = Change()
            onChange(change)
        }
    }
}
