import AVFoundation

/// Long reads of a file (decoding a whole clip's sound) block the thread they run on. They run here, on
/// threads of their own and a few at a time, never on the shared pool that every `async` task needs: a
/// batch of them (35 clips coming in at once) must not leave imports, scans and everything else waiting.
enum BlockingWork {
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "editroom.reading"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 3
        return queue
    }()

    static func run<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { c in
            queue.addOperation {
                c.resume(returning: body())
            }
        }
    }
}

/// Ends an asset read that stops giving samples, as one does when its file is renamed, moved or replaced
/// (by Dropbox, say) partway through: without it the read waits forever. Call `tick()` for each sample.
final class StallGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    private var timer: DispatchSourceTimer?

    init(_ reader: AVAssetReader, after seconds: Double = 15) {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self, weak reader] in
            guard let self else { return }
            self.lock.lock()
            let stalled = Date().timeIntervalSince(self.last) > seconds
            self.lock.unlock()
            if stalled {
                reader?.cancelReading()
                self.stop()
            }
        }
        timer = t
        t.resume()
    }

    func tick() {
        lock.lock()
        last = Date()
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let t = timer
        timer = nil
        lock.unlock()
        t?.cancel()
    }

    deinit { timer?.cancel() }
}
