import Foundation

public enum SocketError: Error, Equatable {
    case create(Int32)
    case bind(Int32)
    case listen(Int32)
    case pathTooLong
}

/// Listens on a Unix domain socket for newline-delimited `AgentEvent` JSON.
///
/// Clients connect, write one or more `\n`-terminated JSON events, then close.
/// `onEvent` is invoked on a background queue, once per decoded event;
/// undecodable lines are skipped.
///
/// Connections are read off the accept loop and therefore **concurrently**:
/// `onEvent` can be called from several threads at once, and events from
/// different connections carry no relative order. Neither is a loss — every
/// hook invocation is its own short-lived process, so the ordering between two
/// of them was already decided by whichever won the race to `connect`.
public final class EventSocketServer: @unchecked Sendable {
    private let path: String
    private let acceptQueue = DispatchQueue(label: "vibescroll.socket.accept")
    /// Concurrent on purpose. `handleClient` blocks in `read`, and doing that on
    /// the accept loop meant one stalled hook process stopped every other
    /// agent's events from arriving at all.
    private let clientQueue = DispatchQueue(
        label: "vibescroll.socket.client", attributes: .concurrent)

    /// Guards `running` and `listenFD`: `stop()` writes both from the caller's
    /// thread while the accept loop reads them on `acceptQueue`.
    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false

    /// A hook writes one small line and closes immediately, so a wait longer
    /// than this is a client that stalled or died mid-write. Bounded rather
    /// than infinite so a wedged connection cannot hold a descriptor and a
    /// thread forever.
    private static let readTimeoutSeconds = 5

    /// Ceiling on what a single connection may send. An event is well under a
    /// kilobyte; anything approaching this is a runaway writer, and buffering
    /// it without limit would make that the daemon's problem.
    static let maxClientBytes = 1 << 20

    public init(path: String) {
        self.path = path
    }

    deinit { stop() }

    public func start(onEvent: @escaping @Sendable (AgentEvent) -> Void) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.create(errno) }

        unlink(path)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else {
            close(fd)
            throw SocketError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, byte) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: byte) }
                dst[pathBytes.count] = 0
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else { close(fd); throw SocketError.bind(errno) }
        guard listen(fd, 16) == 0 else { close(fd); throw SocketError.listen(errno) }

        stateLock.lock()
        listenFD = fd
        running = true
        stateLock.unlock()

        // The listen descriptor is fixed for the lifetime of this run, so it is
        // handed to the loop directly instead of being re-read from shared
        // state on every iteration.
        acceptQueue.async { [weak self] in self?.acceptLoop(fd: fd, onEvent: onEvent) }
    }

    public func stop() {
        stateLock.lock()
        running = false
        let fd = listenFD
        listenFD = -1
        stateLock.unlock()

        // Closing wakes the blocked `accept()`; the loop then re-checks
        // `running` and exits rather than reporting the close as an error.
        if fd >= 0 { close(fd) }
        unlink(path)
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    /// What the accept loop should do after `accept()` returns an error.
    enum AcceptErrorAction: Equatable {
        /// Transient, expected error (interrupted syscall, client aborted) —
        /// loop again right away.
        case retryImmediately
        /// Recoverable resource pressure (fd exhaustion) or an unknown error —
        /// sleep briefly before retrying so a *persistent* error can't spin a
        /// CPU core at 100%.
        case backoff
        /// The listen socket itself is gone (closed/invalid) — retrying can
        /// only ever fail again, so stop the loop instead of spinning.
        case stop
    }

    /// Classifies an `accept()` errno. The default is `.backoff`, never
    /// `.retryImmediately`: an unrecognised error must not fall through to a
    /// tight, CPU-pegging retry loop.
    static func acceptErrorAction(errno code: Int32) -> AcceptErrorAction {
        switch code {
        case EINTR, ECONNABORTED: return .retryImmediately
        case EBADF, EINVAL, ENOTSOCK: return .stop
        default: return .backoff
        }
    }

    private func acceptLoop(fd: Int32, onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        while isRunning {
            let client = accept(fd, nil, nil)
            if client < 0 {
                let err = errno
                guard isRunning else { break }
                switch Self.acceptErrorAction(errno: err) {
                case .retryImmediately: continue
                case .backoff:
                    usleep(50_000)   // 50ms — cap a persistent error at ~20 retries/sec
                    continue
                case .stop: return
                }
            }
            // Handed off rather than read here: the next hook must not wait
            // behind a client that is slow to write, or never closes at all.
            clientQueue.async { Self.handleClient(client, onEvent: onEvent) }
        }
    }

    private static func handleClient(_ fd: Int32, onEvent: @Sendable (AgentEvent) -> Void) {
        defer { close(fd) }

        // Without this a client that connects and then says nothing blocks its
        // handler thread forever.
        var timeout = timeval(tv_sec: readTimeoutSeconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                       socklen_t(MemoryLayout<timeval>.size))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count < maxClientBytes, readMore(fd: fd, into: &buffer, chunk: &chunk) {}
        decodeLines(buffer, onEvent: onEvent)
    }

    /// Reads one chunk from `fd` into `buffer`. Returns `false` at EOF, on error
    /// and on the receive timeout — a partial trailing line simply fails to
    /// decode, which is the same outcome as any other malformed input.
    private static func readMore(fd: Int32, into buffer: inout Data, chunk: inout [UInt8]) -> Bool {
        let n = read(fd, &chunk, chunk.count)
        guard n > 0 else { return false }
        buffer.append(contentsOf: chunk[0..<n])
        return true
    }

    /// Drains a directory of queued event files written while the daemon was
    /// down, emitting each event and removing the file. Files are processed in
    /// name order.
    public static func drainQueue(directory: String, onEvent: (AgentEvent) -> Void) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return }
        for name in names.sorted() {
            let full = (directory as NSString).appendingPathComponent(name)
            if let data = fm.contents(atPath: full) {
                decodeLines(data, onEvent: onEvent)
            }
            try? fm.removeItem(atPath: full)
        }
    }

    static func decodeLines(_ data: Data, onEvent: (AgentEvent) -> Void) {
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let event = try? EventCoding.decoder.decode(AgentEvent.self, from: Data(line)) {
                onEvent(event)
            }
        }
    }
}
