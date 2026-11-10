import Foundation

public enum ShellShimError: Error, Equatable {
    /// A `# >>> localia >>>` line has no matching end marker; the file is left untouched.
    case unterminatedBlock(String)
    /// The rc file is not valid UTF-8; it is left untouched.
    case unreadable(String)
    /// The rc file (or, when it must be created, its directory) is not writable; nothing is changed.
    case notWritable(String)
    /// A value would break the line-based `state.env` format (newline, NUL) or an env name is not allowed.
    case invalidStateValue(String)
}

/// The surface `LocalModeController` needs, so it can be tested without touching rc files.
public protocol ShellShimming: Sendable {
    func install() throws
    func uninstall() throws
    func writeState(on: Bool, baseURL: URL, model: String, contextTokens: Int, policy: EngineDownPolicy,
                    profile: LaunchProfile, engine: EngineID) throws
}

/// The reversible "every `claude`" shim.
///
/// - `install()` writes `claude.zsh` / `claude.bash` into `shimDir` and appends one marked block to each
///   rc file that sources the matching file. Idempotent. Before its first change an rc is backed up to
///   `<rc>.localia-backup-<yyyyMMdd-HHmmss>` with the rc's own permissions, and only if no Localia backup
///   exists yet: the first (pre-Localia) copy is the one kept. A missing `~/.zshrc` is created (zsh is
///   the macOS default); a missing bash rc is skipped. If any rc fails, the ones already changed in this
///   call are restored byte for byte (and their fresh backups removed) before the error is rethrown.
/// - `uninstall()` removes exactly the marked block(s) and nothing else.
/// - `writeState(...)` writes `shimDir/state.env`, which the shim *parses* on every call (never sources).
///
/// Symlinked rc files (dotfiles managers) are edited through the link: the link itself is kept, and the
/// target's permissions are preserved.
public struct ShellShim: ShellShimming {
    public static let beginMarker = "# >>> localia >>>"
    public static let endMarker = "# <<< localia <<<"
    /// How long the shim waits for the engine after asking the app to start it (`autoStart`). llama.cpp
    /// has to start a server and map the whole model, so it gets longer than Ollama.
    public static func startWaitSeconds(_ engine: EngineID) -> Int {
        switch engine {
        case .ollama: return 20
        case .llamaCpp: return 90
        }
    }
    /// Used when `state.env` has no valid `wait=` line (e.g. written by an older version).
    static let defaultStartWaitSeconds = 20

    public let rcFiles: [URL]
    public let shimDir: URL
    public let home: URL
    private let now: @Sendable () -> Date

    public init(rcFiles: [URL], shimDir: URL,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.rcFiles = rcFiles
        self.shimDir = shimDir
        self.home = home
        self.now = now
    }

    /// `~/.zshrc` and `~/.bashrc` for `home`.
    public static func defaultRcFiles(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [home.appendingPathComponent(".zshrc"), home.appendingPathComponent(".bashrc")]
    }

    public var stateFile: URL { shimDir.appendingPathComponent("state.env") }
    /// Isolated Claude Code config used by the light profile (sibling of `shimDir` under AppSupport).
    public var configDir: URL { shimDir.deletingLastPathComponent().appendingPathComponent("claude-config", isDirectory: true) }
    /// Records rc files whose missing final newline `install()` added, so `uninstall()` can take it back.
    private var newlineLedger: URL { shimDir.appendingPathComponent(".rc-newline-added") }

    // MARK: - Install / uninstall

    public func install() throws {
        try writeShimFiles()
        let ledgerBefore = readLedger()
        var done: [Undo] = []
        do {
            for rc in rcFiles { if let u = try installBlock(in: rc) { done.append(u) } }
        } catch {
            for u in done.reversed() { u.restore() }
            try? writeLedger(ledgerBefore)
            throw error
        }
    }

    /// How to put one rc back as it was before this `install()` call.
    private struct Undo {
        let target: URL
        let original: Data?          // nil: the file did not exist
        let permissions: Any?
        let backup: URL?             // created by this call

        func restore() {
            let fm = FileManager.default
            if let original {
                try? original.write(to: target, options: .atomic)
                if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
            } else {
                try? fm.removeItem(at: target)
            }
            if let backup { try? fm.removeItem(at: backup) }
        }
    }

    public func uninstall() throws {
        // Check every file first so a malformed one leaves all of them untouched.
        var plans: [(target: URL, stripped: String, blockAtEnd: Bool)] = []
        for rc in rcFiles {
            guard let target = editableTarget(rc), let text = try readText(target) else { continue }
            guard let stripped = try Self.removingBlocks(from: text, path: rc.path) else { continue }
            guard FileManager.default.isWritableFile(atPath: target.path) else { throw ShellShimError.notWritable(target.path) }
            plans.append((target, stripped, text.hasSuffix(Self.endMarker + "\n")))
        }
        var ledger = readLedger()
        for (target, var stripped, blockAtEnd) in plans {
            if ledger.remove(target.path) != nil, blockAtEnd, stripped.hasSuffix("\n") {
                stripped.removeLast()   // the newline install() added after the user's last line
            }
            try writePreservingAttributes(stripped, to: target)
        }
        try writeLedger(ledger)
    }

    /// Returns how to undo the change, or nil when the file was left alone.
    private func installBlock(in rc: URL) throws -> Undo? {
        let fm = FileManager.default
        let isBash = rc.lastPathComponent.contains("bash")
        let block = blockText(shimFile: isBash ? "claude.bash" : "claude.zsh")

        guard let target = editableTarget(rc) else { return nil }   // dangling symlink: leave it alone
        guard fm.fileExists(atPath: target.path) else {
            if isBash { return nil }
            guard fm.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
                throw ShellShimError.notWritable(target.path)
            }
            try writePreservingAttributes(block, to: target)
            return Undo(target: target, original: nil, permissions: nil, backup: nil)
        }
        guard var text = try readText(target) else { return nil }
        if text.contains(block) { return nil }                       // already installed
        // A read-only rc is a user decision: refuse rather than replace it through the directory.
        guard fm.isWritableFile(atPath: target.path) else { throw ShellShimError.notWritable(target.path) }

        let original = Data(text.utf8)
        let permissions = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions]
        let backupURL = hasBackup(rc) ? nil : try backup(rc: rc, contents: original, permissions: permissions)
        let undo = Undo(target: target, original: original, permissions: permissions, backup: backupURL)
        if let stripped = try Self.removingBlocks(from: text, path: rc.path) { text = stripped }  // stale block
        var ledger = readLedger()
        if !text.isEmpty, !text.hasSuffix("\n") {
            text += "\n"
            ledger.insert(target.path)
            try writeLedger(ledger)
        }
        do { try writePreservingAttributes(text + block, to: target) } catch { undo.restore(); throw error }
        return undo
    }

    /// The exact block `install()` appends to each rc file (`claude.zsh` for zsh, `claude.bash` for bash).
    public func blockText(shimFile: String) -> String {
        let path = Self.doubleQuotedPath(shimDir.appendingPathComponent(shimFile).standardizedFileURL.path, home: home)
        return "\(Self.beginMarker)\n[ -f \(path) ] && source \(path)\n\(Self.endMarker)\n"
    }

    /// `"$HOME/rest"` when the path is inside `home`, otherwise the absolute path, escaped for double quotes.
    static func doubleQuotedPath(_ path: String, home: URL) -> String {
        func esc(_ s: String) -> String {
            var out = ""
            for ch in s { if "\\\"$`".contains(ch) { out.append("\\") }; out.append(ch) }
            return out
        }
        let h = home.standardizedFileURL.path
        if path.hasPrefix(h + "/") { return "\"$HOME/" + esc(String(path.dropFirst(h.count + 1))) + "\"" }
        return "\"" + esc(path) + "\""
    }

    /// Returns the text without any marked block, or nil when there is none.
    static func removingBlocks(from text: String, path: String) throws -> String? {
        var parts = text.components(separatedBy: "\n")
        // .whitespacesAndNewlines so a block whose file was converted to CRLF is still recognised.
        func isLine(_ s: String, _ marker: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines) == marker }
        var changed = false
        var i = 0
        while i < parts.count {
            guard isLine(parts[i], beginMarker) else { i += 1; continue }
            guard let end = parts[(i + 1)...].firstIndex(where: { isLine($0, endMarker) }) else {
                throw ShellShimError.unterminatedBlock(path)
            }
            parts.removeSubrange(i...end)
            changed = true
        }
        return changed ? parts.joined(separator: "\n") : nil
    }

    // MARK: - State

    public func writeState(on: Bool, baseURL: URL, model: String, contextTokens: Int, policy: EngineDownPolicy,
                           profile: LaunchProfile, engine: EngineID) throws {
        let overlay = ClaudeCodeTool.localOverlay(baseURL: baseURL, model: model, contextTokens: contextTokens,
                                                  profile: profile,
                                                  configDir: profile == .light ? configDir : nil)
        let probe = baseURL.appendingPathComponent(Self.healthPath(engine)).absoluteString
        var lines = [
            "# Localia local-mode state. Data only: the shim reads it line by line and never sources it.",
            "version=1",
            "on=\(on ? 1 : 0)",
            "engine=\(engine.rawValue)",
            "base=\(baseURL.absoluteString)",
            "model=\(model)",
            "policy=\(policy.rawValue)",
            "profile=\(profile.rawValue)",
            "probe=\(probe)",
            "start=localia://start?model=\(Self.percentEncode(model))",
            "wait=\(Self.startWaitSeconds(engine))",
        ]
        for (k, v) in overlay.environment.sorted(by: { $0.key < $1.key }) {
            guard Self.isShimEnvName(k) else { throw ShellShimError.invalidStateValue(k) }
            lines.append("env=\(k)=\(v)")
        }
        for k in overlay.unsetEnvironment {
            guard Self.isShimEnvName(k) else { throw ShellShimError.invalidStateValue(k) }
            lines.append("unset=\(k)")
        }
        lines += overlay.arguments.map { "arg=\($0)" }
        for line in lines where line.contains("\n") || line.contains("\r") || line.contains("\0") {
            throw ShellShimError.invalidStateValue(line)
        }

        if on, profile == .light {
            // Onboarding and the API-key approval live in the isolated dir (never ~/.claude*). A bare
            // `claude` can't pre-trust its cwd, so Claude Code may ask once per new folder.
            try ClaudeConfigIsolation(dir: configDir).prepare(apiKey: ClaudeCodeTool.apiKey, trustedFolder: configDir)
        }
        try FileManager.default.createDirectory(at: shimDir, withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: stateFile, options: .atomic)
    }

    static func healthPath(_ engine: EngineID) -> String {
        switch engine {
        case .ollama: return "api/version"
        case .llamaCpp: return "health"
        }
    }

    static func percentEncode(_ s: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// Only these names are ever exported or unset by the shim (it enforces the same rule on its side).
    static func isShimEnvName(_ s: String) -> Bool {
        (s.hasPrefix("ANTHROPIC_") || s.hasPrefix("CLAUDE_"))
            && s.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
    }

    // MARK: - Shim files

    private func writeShimFiles() throws {
        try FileManager.default.createDirectory(at: shimDir, withIntermediateDirectories: true)
        for (name, text) in [("claude.zsh", shimScript(zsh: true)), ("claude.bash", shimScript(zsh: false))] {
            try Data(text.utf8).write(to: shimDir.appendingPathComponent(name), options: .atomic)
        }
    }

    /// POSIX sh body shared by both files. The zsh file only adds `emulate -L sh` so the user's zsh
    /// options (no word splitting, KSH_ARRAYS, NO_UNSET...) cannot change its meaning.
    /// `function claude {` (instead of `claude() {`) keeps a user alias named `claude` from breaking the parse.
    func shimScript(zsh: Bool) -> String {
        let state = LaunchScriptBuilder.shellQuote(stateFile.path)
        let t = Self.defaultStartWaitSeconds
        return """
        # Localia: local-mode shim for \(zsh ? "zsh" : "bash"). Generated by Localia; edits are overwritten.
        # It decides on every call by reading \(stateFile.lastPathComponent) (data only, never sourced), so a
        # crashed, quit or deleted app can never leave `claude` pointing at a dead local server.
        # `command claude` always runs the real binary (the cloud version).
        function claude {
        \(zsh ? "  emulate -L sh\n" : "")  local _l_state _l_line _l_on _l_probe _l_policy _l_start _l_base _l_ready _l_end _l_wait
          _l_state=\(state)
          _l_on=0; _l_probe=; _l_policy=fail; _l_start=; _l_base=; _l_ready=0; _l_wait=\(t)
          if [ -r "$_l_state" ]; then
            while IFS= read -r _l_line || [ -n "$_l_line" ]; do
              case $_l_line in
                on=*) _l_on=${_l_line#on=} ;;
                probe=*) _l_probe=${_l_line#probe=} ;;
                policy=*) _l_policy=${_l_line#policy=} ;;
                start=*) _l_start=${_l_line#start=} ;;
                base=*) _l_base=${_l_line#base=} ;;
                wait=*)
                  # Digits only (1-999, no leading zero) before it reaches $(( )).
                  case ${_l_line#wait=} in ''|*[!0-9]*|0*|????*) ;; *) _l_wait=${_l_line#wait=} ;; esac
                  ;;
              esac
            done < "$_l_state"
          fi
          if [ "$_l_on" != 1 ]; then
            command claude "$@"
            return
          fi
          case $_l_probe in http://*|https://*) ;; *) _l_probe= ;; esac
          if [ -n "$_l_probe" ] && command curl -fsS -m 1 "$_l_probe" >/dev/null 2>&1; then
            _l_ready=1
          else
            case $_l_policy in
              fallBackToCloud)
                printf '%s\\n' 'Localia: local engine down, using cloud' >&2
                command claude "$@"
                return
                ;;
              autoStart)
                case $_l_start in localia://*) ;; *) _l_start= ;; esac
                if [ -z "$_l_start" ] || ! command open -g "$_l_start" >/dev/null 2>&1; then
                  printf '%s\\n' 'Localia: the local engine is not running and could not start Localia (was the app removed?).' \\
                    "Run 'command claude' to use the cloud version." >&2
                  return 1
                fi
                printf '%s\\n' 'Localia: starting the local engine...' >&2
                _l_end=$((SECONDS + $_l_wait))
                while [ "$SECONDS" -lt "$_l_end" ]; do
                  command sleep 0.5
                  if [ -n "$_l_probe" ] && command curl -fsS -m 1 "$_l_probe" >/dev/null 2>&1; then
                    _l_ready=1
                    break
                  fi
                done
                if [ "$_l_ready" != 1 ]; then
                  printf '%s\\n' "Localia: the local engine did not start within $_l_wait s." \\
                    "Run 'command claude' to use the cloud version." >&2
                  return 1
                fi
                ;;
              *)
                printf '%s\\n' "Localia: the local engine is not running at ${_l_base:-its address}." \\
                  "Start it from the Localia menu, or run 'command claude' to use the cloud version." >&2
                return 1
                ;;
            esac
          fi
          # Local run in a subshell so nothing leaks into the calling shell. Only ANTHROPIC_* and
          # CLAUDE_* names are ever exported or unset; profile arguments go before the user's.
          (
            _l_n=$#
            while IFS= read -r _l_line || [ -n "$_l_line" ]; do
              case $_l_line in
                env=ANTHROPIC_*=*|env=CLAUDE_*=*)
                  _l_line=${_l_line#env=}
                  _l_k=${_l_line%%=*}
                  case $_l_k in *[!A-Za-z0-9_]*) continue ;; esac
                  export "$_l_k=${_l_line#*=}"
                  ;;
                unset=ANTHROPIC_*|unset=CLAUDE_*)
                  _l_k=${_l_line#unset=}
                  case $_l_k in *[!A-Za-z0-9_]*) continue ;; esac
                  unset "$_l_k"
                  ;;
                arg=*) set -- "$@" "${_l_line#arg=}" ;;
              esac
            done < "$_l_state"
            _l_i=0
            while [ "$_l_i" -lt "$_l_n" ]; do
              set -- "$@" "$1"
              shift
              _l_i=$((_l_i + 1))
            done
            command claude "$@"
          )
        }

        """
    }

    // MARK: - File plumbing

    /// The file to edit for `rc`: the symlink's target when `rc` is a link (so the link survives), nil for
    /// a dangling link.
    private func editableTarget(_ rc: URL) -> URL? {
        let fm = FileManager.default
        guard (try? fm.destinationOfSymbolicLink(atPath: rc.path)) != nil else { return rc }
        let resolved = rc.resolvingSymlinksInPath()
        return fm.fileExists(atPath: resolved.path) ? resolved : nil
    }

    private func readText(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let s = String(data: data, encoding: .utf8) else { throw ShellShimError.unreadable(url.path) }
        return s
    }

    private func hasBackup(_ rc: URL) -> Bool {
        let prefix = rc.lastPathComponent + ".localia-backup-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: rc.deletingLastPathComponent().path)) ?? []
        return names.contains { $0.hasPrefix(prefix) }
    }

    /// Writes `contents` (the rc target's bytes) next to `rc`. The file is created 0600 with O_EXCL, so it
    /// is never readable by others even briefly, then given the source's own permissions.
    private func backup(rc: URL, contents: Data, permissions: Any?) throws -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stem = rc.path + ".localia-backup-" + f.string(from: now())
        var path = stem, n = 1
        while FileManager.default.fileExists(atPath: path) { n += 1; path = "\(stem)-\(n)" }

        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path]) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: contents)
            if let mode = (permissions as? NSNumber)?.uint16Value { fchmod(fd, mode_t(mode)) }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(atPath: path)
            throw error
        }
        return URL(fileURLWithPath: path)
    }

    /// Atomic replace, then the original permissions are put back (atomic writes create a new inode).
    private func writePreservingAttributes(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        let perms = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions]
        try Data(text.utf8).write(to: url, options: .atomic)
        if let perms { try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path) }
    }

    private func readLedger() -> Set<String> {
        guard let s = try? String(contentsOf: newlineLedger, encoding: .utf8) else { return [] }
        return Set(s.split(separator: "\n").map(String.init))
    }

    private func writeLedger(_ set: Set<String>) throws {
        if set.isEmpty {
            if FileManager.default.fileExists(atPath: newlineLedger.path) { try FileManager.default.removeItem(at: newlineLedger) }
            return
        }
        try FileManager.default.createDirectory(at: shimDir, withIntermediateDirectories: true)
        try Data((set.sorted().joined(separator: "\n") + "\n").utf8).write(to: newlineLedger, options: .atomic)
    }
}
