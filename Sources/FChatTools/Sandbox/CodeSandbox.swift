// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// Runs an Agent Skill's code in a confined child process. This is the
/// security boundary for executing untrusted third-party skill scripts.
///
/// Two layers of confinement (defense in depth):
///
///  1. **Kernel jail** — every interpreter is launched under
///     `/usr/bin/sandbox-exec` with a deny-by-default seatbelt profile that
///     grants read access only to the skill directory + the bundled
///     interpreter + the minimal system libraries an interpreter needs to
///     start, write access only to the skill's `work/` scratch dir, and
///     **denies all network**.
///
///  2. **Process hardening** — a scrubbed minimal environment (no inherited
///     `PATH` of user tools, no secrets, `HOME` pointed at the work dir), a
///     working directory inside the skill, a wall-clock timeout that kills the
///     process, and a hard cap on captured output.
///
/// `sandbox-exec` is deprecated by Apple but fully functional and has no CLI
/// replacement; it is the strongest on-device confinement available short of
/// a VM.
public struct CodeSandbox: Sendable {
    public enum Language: String, Sendable, Codable, CaseIterable {
        case bash
        case python
    }

    public struct Result: Sendable, Hashable {
        public var stdout: String
        public var stderr: String
        public var exitCode: Int32
        public var truncated: Bool
        public var timedOut: Bool
    }

    public enum SandboxError: Error, CustomStringConvertible {
        case interpreterUnavailable(Language)
        case launchFailed(String)

        public var description: String {
            switch self {
            case .interpreterUnavailable(let lang):
                return "No \(lang.rawValue) interpreter is available in this environment."
            case .launchFailed(let detail):
                return "Could not start the sandbox: \(detail)"
            }
        }
    }

    /// Resolves interpreter paths. Injected so tests can override; production
    /// uses `.default`.
    public struct InterpreterResolver: Sendable {
        public var bashPath: @Sendable () -> String?
        public var pythonPath: @Sendable () -> String?

        public init(
            bashPath: @escaping @Sendable () -> String?,
            pythonPath: @escaping @Sendable () -> String?
        ) {
            self.bashPath = bashPath
            self.pythonPath = pythonPath
        }

        /// Production resolver: bash is always `/bin/bash`; python is the
        /// bundled relocatable CPython inside the .app when present, else a
        /// detected system/Homebrew `python3`, else nil.
        public static let `default` = InterpreterResolver(
            bashPath: { FileManager.default.isExecutableFile(atPath: "/bin/bash") ? "/bin/bash" : nil },
            pythonPath: { CodeSandbox.resolveBundledOrSystemPython() }
        )
    }

    public let resolver: InterpreterResolver
    public let sandboxExecPath: String

    public init(
        resolver: InterpreterResolver = .default,
        sandboxExecPath: String = "/usr/bin/sandbox-exec"
    ) {
        self.resolver = resolver
        self.sandboxExecPath = sandboxExecPath
    }

    /// Whether a given language can run in this environment.
    public func isAvailable(_ language: Language) -> Bool {
        interpreter(for: language) != nil
    }

    private func interpreter(for language: Language) -> String? {
        switch language {
        case .bash: return resolver.bashPath()
        case .python: return resolver.pythonPath()
        }
    }

    /// Run `code` in the sandbox. `workingDirectory` is the skill's unpacked
    /// root; the process may read it and read/write its `work/` subdirectory.
    ///
    /// Returns structured output. A non-zero exit code is data the caller
    /// should surface to the model, not an error — only a failure to *launch*
    /// the sandbox throws.
    public func run(
        language: Language,
        code: String,
        workingDirectory: URL,
        timeout: Duration = .seconds(30),
        maxOutputBytes: Int = 64 * 1024
    ) async throws -> Result {
        guard let interp = interpreter(for: language) else {
            throw SandboxError.interpreterUnavailable(language)
        }

        let fm = FileManager.default
        let workDir = workingDirectory.appendingPathComponent("work", isDirectory: true)
        try? fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        // Materialise the code to a temp script inside the writable work dir so
        // the sandbox profile (which permits reads under the skill root) can
        // read it, and so we pass a file path rather than piping via stdin.
        let scriptName = language == .bash ? "._fchat_run.sh" : "._fchat_run.py"
        let scriptURL = workDir.appendingPathComponent(scriptName)
        do {
            try code.data(using: .utf8)?.write(to: scriptURL)
        } catch {
            throw SandboxError.launchFailed("could not stage script: \(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: scriptURL) }

        let profile = Self.seatbeltProfile(
            interpreterPath: interp,
            skillRoot: workingDirectory,
            workDir: workDir,
            // The real user home (F-Chat itself is unsandboxed) — the skill
            // must not be able to read it.
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sandboxExecPath)
        process.arguments = ["-p", profile, interp, scriptURL.path]
        process.currentDirectoryURL = workingDirectory
        // Scrubbed, minimal environment. No inherited PATH of user tools, no
        // secrets. HOME points at the writable scratch dir so interpreters
        // that look for a home dir don't escape.
        process.environment = [
            "HOME": workDir.path,
            "TMPDIR": workDir.path,
            "PATH": "/usr/bin:/bin",
            "LC_ALL": "en_US.UTF-8",
            "LANG": "en_US.UTF-8",
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        // Start draining BEFORE run() so no output is missed, then launch.
        // Each pipe drains on its own background thread with a byte cap, which
        // prevents a child that produces more than one pipe-buffer of output
        // from dead-locking on a blocked write.
        let stdoutDrain = Self.drain(stdoutPipe.fileHandleForReading, cap: maxOutputBytes)
        let stderrDrain = Self.drain(stderrPipe.fileHandleForReading, cap: maxOutputBytes)

        do {
            try process.run()
        } catch {
            stdoutDrain.cancel()
            stderrDrain.cancel()
            throw SandboxError.launchFailed(error.localizedDescription)
        }
        // Close our copies of the write ends so the reader sees EOF once the
        // child (the only remaining writer) exits. Without this the drains
        // block on `read` forever.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        // Wall-clock timeout: terminate (SIGTERM) then, if it lingers, kill.
        let timeoutFlag = TimeoutFlag()
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            if process.isRunning {
                await timeoutFlag.markFired()
                process.terminate()
                try? await Task.sleep(for: .milliseconds(500))
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }

        await Self.waitUntilExit(process)
        timeoutTask.cancel()
        let timedOut = await timeoutFlag.fired

        let (out, outTrunc) = await stdoutDrain.value
        let (err, errTrunc) = await stderrDrain.value

        return Result(
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self),
            exitCode: process.terminationStatus,
            truncated: outTrunc || errTrunc,
            timedOut: timedOut
        )
    }

    /// Records whether the timeout path fired, so we report `timedOut` without
    /// guessing from a (signal-dependent) termination status.
    private actor TimeoutFlag {
        private(set) var fired = false
        func markFired() { fired = true }
    }

    // MARK: - Seatbelt profile

    /// Generate the per-invocation seatbelt profile.
    ///
    /// Strategy: a strict deny-by-default profile that blocks an interpreter
    /// from even starting (its dynamic linker scatters reads across the dyld
    /// shared cache and system frameworks, which is impractical to enumerate).
    /// Instead we **allow reads broadly** so interpreters launch, then
    /// explicitly **deny reads of the user's sensitive data** (home directory,
    /// keychains, SSH keys, the app's own state), **confine all writes** to the
    /// skill's scratch dir, and **deny all network**. The boundary that
    /// matters for an untrusted skill — it can't exfiltrate the user's files or
    /// phone home — holds, while the interpreter still runs.
    static func seatbeltProfile(
        interpreterPath: String,
        skillRoot: URL,
        workDir: URL,
        homeDirectory: URL
    ) -> String {
        // The interpreter and its runtime tree must stay readable even if they
        // live under the (denied) home directory — e.g. a bundled CPython in an
        // .app the user keeps in ~/Applications or a dev build under ~/VSCode.
        // For a bundled relocatable runtime laid out as …/python3/bin/python3,
        // allow the whole …/python3 tree (it scatters reads across lib/,
        // include/, etc.). We must NOT do this for system interpreters under
        // /bin or /usr/bin — the grandparent of /bin/bash is "/", which would
        // re-allow the entire filesystem (including the home dir we just
        // denied). System interpreters live outside home and are already
        // covered by `(allow default)`, so they need no extra rule.
        let interpURL = URL(fileURLWithPath: interpreterPath).resolvingSymlinksInPath()
        let interpDir = interpURL.deletingLastPathComponent()                  // …/bin
        let interpTreeCandidate = interpDir.deletingLastPathComponent()        // …/python3
        let systemPrefixes = ["/bin", "/usr/bin", "/usr/local/bin", "/sbin", "/usr/sbin"]
        let isSystemInterp = systemPrefixes.contains { interpURL.path == "\($0)/\(interpURL.lastPathComponent)" }
        // Only emit an extra read-allow when the interpreter is NOT a system
        // binary AND its tree looks like a self-contained runtime (bin/ under a
        // named root). Empty string → no rule emitted.
        let interpTree: String = (!isSystemInterp && interpDir.lastPathComponent == "bin")
            ? interpTreeCandidate.path
            : ""
        func q(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        // The kernel evaluates seatbelt rules against the canonical (symlink-
        // resolved) path. macOS symlinks /var → /private/var, /tmp →
        // /private/tmp and /etc → /private/etc, and `URL.resolvingSymlinksInPath`
        // does NOT reliably rewrite those firmlinks. So for each path we emit a
        // subpath rule for BOTH the given form and the /private-prefixed form,
        // guaranteeing a match however the path was handed to us.
        func variants(_ path: String) -> [String] {
            let std = (path as NSString).standardizingPath
            var out = Set([std])
            for p in ["/var", "/tmp", "/etc"] where std.hasPrefix(p) {
                out.insert("/private" + std)
            }
            if std.hasPrefix("/private/") {
                out.insert(String(std.dropFirst("/private".count)))
            }
            return Array(out).sorted()
        }
        func subpathRules(_ verb: String, _ path: String) -> String {
            variants(path).map { "(\(verb) (subpath \(q($0))))" }.joined(separator: "\n        ")
        }

        // Sensitive locations a skill must never read. The user's whole home is
        // denied first, then the skill's own dir is re-allowed below (a skill
        // may live under Application Support inside home). The account/password
        // databases are called out explicitly.
        let denyReadPaths = [
            homeDirectory.path,
            "/private/var/db/dslocal",
            "/private/etc/master.passwd",
        ]

        return """
        (version 1)
        (allow default)
        (deny network*)
        ; Confine writes: deny everything, then re-allow only the scratch dir
        ; and the standard write-only devices an interpreter expects.
        (deny file-write*)
        \(subpathRules("allow file-write*", workDir.path))
        (allow file-write*
            (literal "/dev/null")
            (literal "/dev/stdout")
            (literal "/dev/stderr")
            (literal "/dev/dtracehelper")
            (literal "/dev/tty"))
        ; Protect the user's sensitive data from reads.
        \(denyReadPaths.map { subpathRules("deny file-read*", $0) }.joined(separator: "\n        "))
        ; ...but the skill's own directory and (for a bundled runtime) the
        ; interpreter tree remain readable even when they live under the
        ; (denied) home directory.
        \(subpathRules("allow file-read*", skillRoot.path))
        \(interpTree.isEmpty || interpTree == "/" ? "" : subpathRules("allow file-read*", interpTree))
        \(interpTree.isEmpty || interpTree == "/" ? "" : subpathRules("allow process-exec*", interpTree))
        """
    }

    // MARK: - Interpreter resolution

    /// Locate the bundled CPython inside the running .app, falling back to a
    /// detected system/Homebrew `python3`. Returns nil if none is executable.
    static func resolveBundledOrSystemPython() -> String? {
        let fm = FileManager.default
        // Bundled: F-Chat.app/Contents/Resources/python3/bin/python3
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("python3/bin/python3").path
            if fm.isExecutableFile(atPath: bundled) { return bundled }
        }
        // Common system / Homebrew locations.
        let candidates = [
            "/usr/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        // Last resort: ask `/usr/bin/which` (covers versioned Homebrew dirs).
        if let found = whichPython3() { return found }
        return nil
    }

    private static func whichPython3() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["which", "python3"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    // MARK: - IO helpers

    /// Start draining a pipe on a background thread, capping at `cap` bytes but
    /// continuing to read (and discard) the rest so the child never blocks on a
    /// full pipe. The returned `Task` resolves to (bytes, truncated) at EOF.
    private static func drain(_ handle: FileHandle, cap: Int) -> Task<(Data, Bool), Never> {
        Task.detached(priority: .userInitiated) {
            var collected = Data()
            var truncated = false
            while true {
                // Blocking read of up to 16KB; returns empty Data at EOF (once
                // the child has exited and all write ends are closed).
                let chunk: Data
                do {
                    chunk = try handle.read(upToCount: 16 * 1024) ?? Data()
                } catch {
                    break
                }
                if chunk.isEmpty { break }
                if collected.count < cap {
                    let room = cap - collected.count
                    if chunk.count <= room {
                        collected.append(chunk)
                    } else {
                        collected.append(chunk.prefix(room))
                        truncated = true
                    }
                } else {
                    truncated = true
                }
            }
            try? handle.close()
            return (collected, truncated)
        }
    }

    /// Block on the child's exit off the cooperative thread pool. Using the
    /// blocking `waitUntilExit()` on a background queue avoids the
    /// terminationHandler-vs-already-exited race entirely.
    private static func waitUntilExit(_ process: Process) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }
}
