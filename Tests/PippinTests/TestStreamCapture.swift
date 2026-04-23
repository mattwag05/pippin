import Foundation
import XCTest

/// Redirect stdout via `dup`/`dup2` for the duration of `body`, then restore.
/// Used by tests that assert on `print()` output (agent envelope, OutputOptions
/// emitters, etc).
func captureStdout(_ body: () throws -> Void) rethrows -> String {
    fflush(stdout)
    let originalFD = dup(fileno(stdout))
    defer { close(originalFD) }
    let pipe = Pipe()
    dup2(pipe.fileHandleForWriting.fileDescriptor, fileno(stdout))
    try body()
    fflush(stdout)
    pipe.fileHandleForWriting.closeFile()
    dup2(originalFD, fileno(stdout))
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

/// Stderr counterpart to `captureStdout`. Some emitters write advisories
/// (`Warning: ...`) to stderr that need to be assertable in tests.
func captureStderr(_ body: () throws -> Void) rethrows -> String {
    fflush(stderr)
    let originalFD = dup(fileno(stderr))
    defer { close(originalFD) }
    let pipe = Pipe()
    dup2(pipe.fileHandleForWriting.fileDescriptor, fileno(stderr))
    try body()
    fflush(stderr)
    pipe.fileHandleForWriting.closeFile()
    dup2(originalFD, fileno(stderr))
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}
