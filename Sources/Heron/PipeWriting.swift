import Foundation

/// Writing to a child's stdin without letting its exit kill us (2026-09-30 audit, H1).
///
/// A write to a pipe whose reader has gone raises SIGPIPE, and its default action ends the
/// process: a formatter that exits without reading a large file, or a language server or agent
/// that crashes between our `isRunning` check and the write, took Side down with every unsaved
/// buffer. `F_SETNOSIGPIPE` turns that into an EPIPE for this descriptor only, which a library
/// can do without changing the host's signal handling, and `write(contentsOf:)` reports it as
/// an error (the older `write(_:)` raises an exception instead).
public enum PipeWriting {
    /// False when the reader is gone (or the write failed otherwise).
    @discardableResult
    public static func write(_ data: Data, to handle: FileHandle) -> Bool {
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }
}
