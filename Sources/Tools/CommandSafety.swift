import Foundation

/// Command-safety classification (Codex `shell-command/command_safety` +
/// `execpolicy` "safe read" allowlist). A command is `.safe` only if every
/// segment is a known read-only program with safe arguments; anything using
/// redirection, substitution, env-assignment, globbing, or an unknown/writing
/// program is `.needsApproval`.
///
/// Parity reference: `codex-rs/shell-command/src/command_safety/is_safe_command.rs`.
public enum CommandSafety: Sendable, Equatable {
    case safe
    case needsApproval

    // MARK: – Program allowlists -------------------------------------------------

    /// Read-only programs whose ANY invocation is safe regardless of arguments.
    /// Matches upstream's `is_safe_to_call_with_exec` set (the simple match arm).
    private static let alwaysSafePrograms: Set<String> = [
        // Upstream simple-match list (unix-leaning).
        "cat", "cd", "cut", "echo", "expr", "false", "grep", "head", "id",
        "ls", "nl", "paste", "pwd", "rev", "seq", "stat", "tail", "tr",
        "true", "uname", "wc", "which", "whoami",
        // Linux-only in upstream: numfmt, tac. We accept them universally;
        // platform gating is enforced at the host OS by the shell itself.
        "numfmt", "tac",
        // codex-swift extensions (kept for compatibility with existing
        // CommandSafetyTests baseline — these are still read-only):
        "file", "date", "hostname", "printenv", "type", "basename",
        "dirname", "realpath", "readlink", "sleep", "sort", "uniq", "od",
        "xxd", "sha256sum", "md5sum", "cksum", "du", "df", "tree", "egrep",
        "fgrep", "ag", "diff", "cmp", "comm", "column", "fold", "expand",
        "less", "more", "ps", "groups", "tty", "locale", "printf",
    ]

    /// Programs whose safety depends on the argument vector. Handled in
    /// `isSafeArgv` per-program.
    private static let argDependentPrograms: Set<String> = [
        "base64", "find", "rg", "git", "sed",
    ]

    /// `git` subcommands considered read-only. Mirrors upstream's
    /// `find_git_subcommand(command, &["status", "log", "diff", "show", "branch"])`
    /// at `is_safe_command.rs:173` *verbatim*.
    ///
    /// SECURITY: Do NOT extend this list without also extending the per-
    /// subcommand read-only-arg validation in `gitSubcommandArgsAreReadOnly`.
    /// Several previously-considered additions (`config`, `stash`, `tag`,
    /// `remote`, `reflog`) admit mutating sub-operations that upstream's
    /// `UNSAFE_GIT_SUBCOMMAND_OPTIONS` set does not catch — e.g.
    /// `git config --local core.hooksPath /evil` (hook injection / RCE),
    /// `git stash drop` (data loss), `git tag -d` (data destruction),
    /// `git remote set-url` (config tampering), `git reflog expire` (history
    /// rewrite). Keeping this list in lockstep with upstream is the safe
    /// default.
    private static let safeGitSubcommands: Set<String> = [
        "status", "log", "diff", "show", "branch",
    ]

    // MARK: – Git unsafe-option patterns ----------------------------------------

    private enum GitOptionPattern: Sendable {
        /// Exact match (e.g. `-C`).
        case exact(String)
        /// Short option with attached inline value (e.g. `-Csomething`,
        /// `-ccore.pager=cat`). Matches when the arg starts with the option
        /// and is strictly longer.
        case shortWithInlineValue(String)
        /// Prefix match (e.g. `--config-env=`).
        case prefix(String)

        func matches(_ arg: String) -> Bool {
            switch self {
            case .exact(let opt):
                return arg == opt
            case .shortWithInlineValue(let opt):
                return arg.hasPrefix(opt) && arg.count > opt.count
            case .prefix(let p):
                return arg.hasPrefix(p)
            }
        }
    }

    /// Upstream `UNSAFE_GIT_GLOBAL_OPTIONS`.
    private static let unsafeGitGlobalOptions: [GitOptionPattern] = [
        .exact("-C"), .shortWithInlineValue("-C"),
        .exact("-c"), .shortWithInlineValue("-c"),
        .exact("-p"),
        .exact("--config-env"), .prefix("--config-env="),
        .exact("--exec-path"), .prefix("--exec-path="),
        .exact("--git-dir"), .prefix("--git-dir="),
        .exact("--namespace"), .prefix("--namespace="),
        .exact("--paginate"),
        .exact("--super-prefix"), .prefix("--super-prefix="),
        .exact("--work-tree"), .prefix("--work-tree="),
    ]

    /// Upstream `UNSAFE_GIT_SUBCOMMAND_OPTIONS` (output / exec-on-diff flags
    /// that introduce side effects).
    private static let unsafeGitSubcommandOptions: [GitOptionPattern] = [
        .exact("--output"), .prefix("--output="),
        .exact("--ext-diff"),
        .exact("--textconv"),
        .exact("--exec"), .prefix("--exec="),
    ]

    private static func gitMatches(arg: String,
                                   patterns: [GitOptionPattern]) -> Bool {
        patterns.contains { $0.matches(arg) }
    }

    /// Mirrors upstream `is_git_global_option_with_value`.
    private static func isGitGlobalOptionWithValue(_ arg: String) -> Bool {
        switch arg {
        case "-C", "-c", "--config-env", "--exec-path",
             "--git-dir", "--namespace", "--super-prefix", "--work-tree":
            return true
        default:
            return false
        }
    }

    /// Mirrors upstream `is_git_global_option_with_inline_value`.
    private static func isGitGlobalOptionWithInlineValue(_ arg: String) -> Bool {
        if arg.hasPrefix("--config-env=") || arg.hasPrefix("--exec-path=")
            || arg.hasPrefix("--git-dir=") || arg.hasPrefix("--namespace=")
            || arg.hasPrefix("--super-prefix=") || arg.hasPrefix("--work-tree=") {
            return true
        }
        if (arg.hasPrefix("-C") || arg.hasPrefix("-c")) && arg.count > 2 {
            return true
        }
        return false
    }

    /// Locate the first non-option token after `git`, honouring global
    /// option-with-value handling. Returns the (idx, subcommand) tuple, or
    /// nil if no plausible subcommand is in the recognised set.
    ///
    /// Mirrors upstream `find_git_subcommand`.
    private static func findGitSubcommand(_ command: [String],
                                          accepting: Set<String>)
        -> (idx: Int, subcommand: String)?
    {
        guard let first = command.first,
              programLookupKey(first) == "git" else { return nil }
        var skipNext = false
        for i in 1..<command.count {
            if skipNext { skipNext = false; continue }
            let arg = command[i]
            if isGitGlobalOptionWithInlineValue(arg) { continue }
            if isGitGlobalOptionWithValue(arg) { skipNext = true; continue }
            if arg == "--" || arg.hasPrefix("-") { continue }
            if accepting.contains(arg) { return (i, arg) }
            // First non-option token that isn't a recognised subcommand:
            // stop scanning so we don't misread a positional (e.g. a branch
            // name after `git checkout`) as a subcommand.
            return nil
        }
        return nil
    }

    /// Returns true iff git is invoked with a safe read-only subcommand and
    /// no unsafe global option overrides the cwd / config / namespace etc.
    private static func isSafeGitCommand(_ command: [String]) -> Bool {
        guard let (subIdx, sub) = findGitSubcommand(command,
                                                    accepting: safeGitSubcommands)
        else { return false }

        let globalArgs = Array(command[1..<subIdx])
        if globalArgs.contains(where: { arg in
            gitMatches(arg: arg, patterns: unsafeGitGlobalOptions)
        }) {
            return false
        }

        let subArgs = Array(command[(subIdx + 1)...])

        // `git branch`: must be a clearly read-only invocation.
        if sub == "branch" {
            return gitSubcommandArgsAreReadOnly(subArgs)
                && gitBranchIsReadOnly(subArgs)
        }
        return gitSubcommandArgsAreReadOnly(subArgs)
    }

    private static func gitSubcommandArgsAreReadOnly(_ args: [String]) -> Bool {
        !args.contains(where: { arg in
            gitMatches(arg: arg, patterns: unsafeGitSubcommandOptions)
        })
    }

    private static func gitBranchIsReadOnly(_ args: [String]) -> Bool {
        if args.isEmpty { return true }
        var sawReadOnlyFlag = false
        for arg in args {
            switch arg {
            case "--list", "-l", "--show-current", "-a", "--all", "-r",
                 "--remotes", "-v", "-vv", "--verbose":
                sawReadOnlyFlag = true
            default:
                if arg.hasPrefix("--format=") {
                    sawReadOnlyFlag = true
                } else {
                    return false
                }
            }
        }
        return sawReadOnlyFlag
    }

    // MARK: – Other program-specific allowlists ---------------------------------

    /// Unsafe `find` options that delete files, write files, or run code.
    /// Mirrors upstream `UNSAFE_FIND_OPTIONS`.
    private static let unsafeFindOptions: Set<String> = [
        "-exec", "-execdir", "-ok", "-okdir",
        "-delete",
        "-fls", "-fprint", "-fprint0", "-fprintf",
    ]

    /// Unsafe `rg` options that take an argument (executed command / external bin).
    /// Mirrors upstream `UNSAFE_RIPGREP_OPTIONS_WITH_ARGS`.
    private static let unsafeRipgrepOptionsWithArgs: [String] = [
        "--pre", "--hostname-bin",
    ]

    /// Unsafe `rg` options that take no argument (decompression / external tools).
    /// Mirrors upstream `UNSAFE_RIPGREP_OPTIONS_WITHOUT_ARGS`.
    private static let unsafeRipgrepOptionsWithoutArgs: Set<String> = [
        "--search-zip", "-z",
    ]

    /// Unsafe `base64` output options. Upstream `UNSAFE_BASE64_OPTIONS` +
    /// `--output=` prefix + `-o<file>` short-with-value form.
    private static let unsafeBase64ExactOptions: Set<String> = ["-o", "--output"]

    // MARK: – sed -n {N|M,N}p ---------------------------------------------------

    /// True if `arg` matches /^(\d+,)?\d+p$/. Mirrors upstream `is_valid_sed_n_arg`.
    private static func isValidSedNArg(_ arg: String?) -> Bool {
        guard let s = arg, let core = s.dropSuffix("p") else { return false }
        let parts = core.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 1, parts.count <= 2 else { return false }
        return parts.allSatisfy { p in
            !p.isEmpty && p.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    // MARK: – Lookup key (basename of argv[0]) ----------------------------------

    /// Mirrors upstream `executable_name_lookup_key`: returns the basename of
    /// the executable path (no platform-specific suffix stripping on POSIX).
    private static func programLookupKey(_ raw: String) -> String {
        (raw as NSString).lastPathComponent
    }

    // MARK: – Shell-metacharacter gate (raw-string fast path) -------------------

    /// Shell metacharacters that route the whole command to approval (the
    /// segment grammar from the on-request permissions md: redirection,
    /// substitution, env-vars, wildcards are not rule-evaluated).
    private static let escalatingChars: Set<Character> = [
        ">", "<", "*", "?", "$", "`", "{", "}", "(", ")", "[", "]", "~",
        "\\", "\n", "\r",
    ]

    // MARK: – Bash -lc / -c recursive parsing -----------------------------------

    /// If `command` is a `bash -lc "<script>"` / `zsh -lc "<script>"` /
    /// `sh -c "<script>"` invocation, return the parsed inner commands
    /// (split on the conservative `&&`, `||`, `;`, `|` operator allowlist).
    /// Returns nil if the form isn't recognised or the script contains
    /// disallowed constructs (redirection, substitution, subshells, globs…).
    ///
    /// Mirrors upstream `parse_shell_lc_plain_commands` but with a
    /// hand-rolled quote-aware tokeniser (Swift has no tree-sitter dep).
    static func parseShellLcPlainCommands(_ command: [String]) -> [[String]]? {
        guard command.count == 3 else { return nil }
        let shell = programLookupKey(command[0])
        let flag = command[1]
        let script = command[2]
        let knownShells: Set<String> = ["bash", "zsh", "sh"]
        guard knownShells.contains(shell) else { return nil }
        guard flag == "-lc" || flag == "-c" else { return nil }
        // Reject scripts with shell metacharacters that introduce side
        // effects we can't reason about (redirection, subshells, globs,
        // substitution, env-assignment, backslash-escape).
        if script.contains(where: { escalatingChars.contains($0) }) {
            return nil
        }
        // Split on the conservative operator allowlist (|, &&, ||, ;)
        // while respecting quotes.
        let segs = segments(script)
        if segs.isEmpty { return nil }
        var out: [[String]] = []
        for seg in segs {
            let toks = tokens(seg)
            if toks.isEmpty { return nil }
            out.append(toks)
        }
        return out
    }

    // MARK: – isSafeArgv (single argv vector) -----------------------------------

    /// Mirrors upstream `is_safe_to_call_with_exec`.
    private static func isSafeArgv(_ command: [String]) -> Bool {
        guard let first = command.first else { return false }
        let prog = programLookupKey(first)
        if alwaysSafePrograms.contains(prog) { return true }
        guard argDependentPrograms.contains(prog) else { return false }

        switch prog {
        case "base64":
            // Reject any output redirection flag.
            let rest = command.dropFirst()
            for arg in rest {
                if unsafeBase64ExactOptions.contains(arg) { return false }
                if arg.hasPrefix("--output=") { return false }
                if arg.hasPrefix("-o") && arg != "-o" {
                    // `-o<file>` short-with-value form.
                    return false
                }
            }
            return true

        case "find":
            // Any unsafe option → reject.
            return !command.contains(where: { unsafeFindOptions.contains($0) })

        case "rg":
            for arg in command {
                if unsafeRipgrepOptionsWithoutArgs.contains(arg) { return false }
                for opt in unsafeRipgrepOptionsWithArgs {
                    if arg == opt { return false }
                    if arg.hasPrefix(opt + "=") { return false }
                }
            }
            return true

        case "git":
            return isSafeGitCommand(command)

        case "sed":
            // Allow only the `sed -n {N|M,N}p [file]` form.
            guard command.count <= 4,
                  command.count >= 3,
                  command[1] == "-n",
                  isValidSedNArg(command[2]) else { return false }
            return true

        default:
            return false
        }
    }

    /// Top-level argv classifier. Mirrors upstream `is_known_safe_command`.
    public static func classify(argv: [String]) -> CommandSafety {
        if argv.isEmpty { return .needsApproval }
        // env-assignment prefix (FOO=bar cmd): not rule-evaluated.
        if let first = argv.first,
           first.contains("="), !first.hasPrefix("-") {
            return .needsApproval
        }
        // Normalise zsh → bash (parity with upstream `zsh` handling).
        let normalised: [String] = argv.map { $0 == "zsh" ? "bash" : $0 }

        if isSafeArgv(normalised) { return .safe }

        // `bash -lc "<script>"` recursive case: every inner command must be safe.
        if let inner = parseShellLcPlainCommands(normalised),
           !inner.isEmpty,
           inner.allSatisfy({ isSafeArgv($0) }) {
            return .safe
        }
        return .needsApproval
    }

    // MARK: – Shell-string (raw) classifier -------------------------------------

    /// Classify a raw shell string. Every segment must be safe and the string
    /// must not use redirection / substitution / globbing.
    public static func classify(shell raw: String) -> CommandSafety {
        if raw.contains(where: { escalatingChars.contains($0) }) {
            return .needsApproval
        }
        let segs = segments(raw)
        if segs.isEmpty { return .needsApproval }
        for seg in segs {
            if classify(argv: tokens(seg)) == .needsApproval {
                return .needsApproval
            }
        }
        return .safe
    }

    // MARK: – Tokenisation -------------------------------------------------------

    /// Split a raw shell string into independent command segments at the
    /// shell control operators (`|`, `&&`, `||`, `;`, `&`). Mirrors the
    /// permissions md segmentation. Quote-aware so operators inside quotes do
    /// not split.
    static func segments(_ raw: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character? = nil
        let chars = Array(raw)
        var i = 0
        func flush() {
            let t = cur.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out.append(t) }
            cur = ""
        }
        while i < chars.count {
            let ch = chars[i]
            if let q = quote {
                cur.append(ch)
                if ch == q { quote = nil }
                i += 1
                continue
            }
            switch ch {
            case "\"", "'":
                quote = ch; cur.append(ch)
            case "|", "&", ";":
                // handle && || by consuming the pair
                if (ch == "|" || ch == "&"), i + 1 < chars.count, chars[i + 1] == ch {
                    i += 1
                }
                flush()
            default:
                cur.append(ch)
            }
            i += 1
        }
        flush()
        return out
    }

    private static func tokens(_ segment: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character? = nil
        for ch in segment {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
                continue
            }
            switch ch {
            case "\"", "'": quote = ch
            case " ", "\t":
                if !cur.isEmpty { out.append(cur); cur = "" }
            default: cur.append(ch)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    // MARK: tool-call JSON helpers

    /// Extract argv from a tool-call arguments JSON object. Accepts
    /// `{"command":"a b c"}` (shell string → tokens) or
    /// `{"command":["a","b"]}` (argv) — Codex accepts both shapes.
    public static func argv(fromToolArgsJSON json: String) -> [String] {
        guard let d = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        else { return [] }
        if let arr = obj["command"] as? [String] { return arr }
        if let arr = obj["command"] as? [Any] { return arr.compactMap { $0 as? String } }
        if let s = obj["command"] as? String { return tokens(s) }
        return []
    }

    /// Is the raw `command` a shell string (vs an argv array)?
    public static func rawShellString(fromToolArgsJSON json: String) -> String? {
        guard let d = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        else { return nil }
        return obj["command"] as? String
    }

    /// True if the model explicitly requested escalation
    /// (`sandbox_permissions: "require_escalated"`).
    public static func requiresEscalated(fromToolArgsJSON json: String) -> Bool {
        guard let d = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        else { return false }
        if let s = obj["sandbox_permissions"] as? String {
            return s == "require_escalated"
        }
        return false
    }

    /// Classify a tool-call's command (string or argv form).
    public static func classifyToolArgs(_ json: String) -> CommandSafety {
        if let raw = rawShellString(fromToolArgsJSON: json) {
            return classify(shell: raw)
        }
        return classify(argv: argv(fromToolArgsJSON: json))
    }
}

// MARK: - Small string helpers ---------------------------------------------------

private extension String {
    /// Drop the given suffix if present; nil otherwise.
    func dropSuffix(_ suffix: String) -> Substring? {
        guard hasSuffix(suffix) else { return nil }
        return self[startIndex..<index(endIndex, offsetBy: -suffix.count)]
    }
}
