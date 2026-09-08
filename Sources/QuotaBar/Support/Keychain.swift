import Foundation
import Security
import os

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

enum Keychain {
    /// Uses Claude Code's system-tool identity to read the current credential.
    /// macOS may request authorization when the tool's access is unavailable.
    static func genericPassword(service: String, account: String = NSUserName()) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let result = try run(process)
        return try password(exitCode: result.exitCode, data: result.data)
    }

    static func password(exitCode: Int32, data: Data) throws -> Data {
        if exitCode != 0 {
            // The security tool returns the low byte of OSStatus as its exit code.
            let statuses: [OSStatus] = [errSecItemNotFound, errSecAuthFailed,
                                       errSecInteractionNotAllowed, errSecUserCanceled]
            let status = statuses.first { Int32(UInt8(truncatingIfNeeded: $0)) == exitCode }
                ?? errSecInternalComponent
            throw KeychainError(status: status)
        }
        guard !data.isEmpty else { throw KeychainError(status: errSecDecode) }
        return data
    }

    /// Drains stdout while the tool runs; credential data stays in memory.
    static func run(_ process: Process, timeout: TimeInterval = 15,
                    outputLimit: Int = 4 * 1024 * 1024) throws -> (exitCode: Int32, data: Data) {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)
        let output = OSAllocatedUnfairLock(initialState: (data: Data(), failed: false))
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        DispatchQueue.global(qos: .utility).async {
            defer { drained.signal() }
            do {
                while let chunk = try pipe.fileHandleForReading.read(upToCount: 16 * 1024), !chunk.isEmpty {
                    let overflow = output.withLock { state in
                        guard state.data.count + chunk.count <= outputLimit else {
                            state.failed = true
                            return true
                        }
                        state.data.append(chunk)
                        return false
                    }
                    if overflow {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        break
                    }
                }
            } catch {
                output.withLock { $0.failed = true }
            }
        }

        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = exited.wait(timeout: .now() + 1)
        }
        let outputFinished = drained.wait(timeout: .now() + 1) == .success
        if outputFinished { try? pipe.fileHandleForReading.close() }
        if timedOut { throw URLError(.timedOut) }
        let result = output.withLock { $0 }
        guard outputFinished, !result.failed else { throw KeychainError(status: errSecDecode) }
        return (process.terminationStatus, result.data)
    }
}
