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
        // Upstream simple-match list (unix-leaning), verbatim from
        // `is_safe_to_call_with_exec` (`is_safe_command.rs:71-98`). Do NOT add
        // programs here that upstream does not auto-trust: anything outside this
        // set (e.g. `sort`, `printf`, `diff`, `du`, `df`, `tree`, `less`,
        // `more`, `ps`, `date`, `file`, `printenv`, `realpath`, `sleep`) must
        // fall through to the approval-prompt path. `less`/`more` admit shell
        // escapes and `sort -o`/redirection are not gated here, so auto-trusting
        // them would widen the approval-bypass surface relative to upstream.
        "cat", "cd", "cut", "echo", "expr", "false", "grep", "head", "id",
        "ls", "nl", "paste", "pwd", "rev", "seq", "stat", "tail", "tr",
        "true", "uname", "uniq", "wc", "which", "whoami",
        // Linux-only in upstream: numfmt, tac. We accept them universally;
        // platform gating is enforced at the host OS by the shell itself.
        "numfmt", "tac",
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

    /// If `command` is a `bash -lc "<script>"` / `zsh -lc` / `sh -c` invocation
    /// whose script is a SINGLE command attaching its stdin via a here-doc
    /// (`<<` / `<<-`) — and nothing else — return the executable-prefix argv of
    /// that single command (literal words only). Returns nil otherwise.
    ///
    /// Mirrors upstream `parse_shell_lc_single_command_prefix`
    /// (`shell-command/src/bash.rs:124-140`): a here-doc only attaches stdin and
    /// does not change argv-matching semantics for the executable prefix, so it
    /// is safe to collapse to the prefix for execpolicy classification — but the
    /// caller MUST treat this as "complex parsing" (see `usedComplexParsing`),
    /// suppressing the known-safe auto-allow so the user is still prompted.
    ///
    /// This path is reached ONLY for scripts that `parseShellLcPlainCommands`
    /// rejected (here-docs contain `<` which is an escalating char), so the two
    /// decomposition paths never both fire for the same script. The Swift
    /// implementation is a hand-rolled, deliberately conservative reproduction
    /// (no tree-sitter): it rejects anything beyond one here-doc-fed command of
    /// literal words.
    static func parseShellLcSingleCommandPrefix(_ command: [String]) -> [String]? {
        guard command.count == 3 else { return nil }
        let shell = programLookupKey(command[0])
        let flag = command[1]
        let script = command[2]
        let knownShells: Set<String> = ["bash", "zsh", "sh"]
        guard knownShells.contains(shell) else { return nil }
        guard flag == "-lc" || flag == "-c" else { return nil }

        // Must contain a here-doc redirect (`<<`) — but NOT a here-string
        // (`<<<`), which upstream's grammar surfaces as a `herestring_redirect`
        // that can smuggle substitutions (e.g. `<<< "$(rm -rf /)"`). Require a
        // `<<` that is not immediately followed by another `<`.
        guard let heredocRange = Self.firstHeredocOperator(in: script) else { return nil }

        // The portion of the script BEFORE the here-doc body delimiter line is
        // the command line; everything after the first newline is the body.
        // We only classify the command line (the executable prefix).
        let commandLine: String
        if let nl = script.firstIndex(of: "\n") {
            commandLine = String(script[..<nl])
        } else {
            commandLine = script
        }
        // The here-doc operator must appear on the command line.
        guard heredocRange.lowerBound < (script.firstIndex(of: "\n") ?? script.endIndex) else {
            return nil
        }

        // Split the command line into the part before the `<<` (the command +
        // its args) and the part after (the delimiter, optionally with a
        // trailing redirect that we must reject).
        let beforeHeredoc = String(script[script.startIndex..<heredocRange.lowerBound])
        let afterHeredoc = String(script[heredocRange.upperBound...])
        // `afterHeredoc` (still on the command line) is the here-doc delimiter
        // token, e.g. `'PY'` / `PY`. Anything beyond a single bare/quoted token
        // (e.g. an extra `> /tmp/out.txt` file redirect, or `&&` chaining) means
        // this is not a lone here-doc-fed command → reject.
        let afterLine: String
        if let nl = afterHeredoc.firstIndex(of: "\n") {
            afterLine = String(afterHeredoc[..<nl])
        } else {
            afterLine = afterHeredoc
        }
        let delimTokens = tokens(afterLine)
        guard delimTokens.count == 1 else { return nil }

        // The command-and-args portion must not contain any shell metacharacter
        // that introduces side effects we can't reason about (redirection,
        // substitution, subshells, globs, env-assignment prefix, arithmetic
        // expansion like `$((1<<2))`, chaining). This mirrors the tree-sitter
        // rejections (`has_error`, word-expansion, file_redirect, multi-command,
        // variable assignment).
        if beforeHeredoc.contains(where: { escalatingChars.contains($0) }) {
            return nil
        }
        // The control operators that `escalatingChars` does NOT include
        // (`|`, `&`, `;`) would indicate multiple commands — reject those too.
        if beforeHeredoc.contains("|") || beforeHeredoc.contains("&")
            || beforeHeredoc.contains(";") {
            return nil
        }
        let toks = tokens(beforeHeredoc)
        guard let head = toks.first, !head.isEmpty else { return nil }
        // Reject an env-assignment prefix (`PATH=/tmp/evil:$PATH cat ...`):
        // matches upstream's rejection of a leading `variable_assignment`.
        if head.contains("="), !head.hasPrefix("-") { return nil }
        return toks
    }

    /// Locate the first here-doc operator (`<<`, but not the here-string
    /// `<<<`) in `script`, returning the range of the `<<` token. Returns nil
    /// when there is no plain here-doc (e.g. only a here-string, or `<` file
    /// redirects, or an arithmetic `$((1<<2))` — though those carry `$`/`(` and
    /// are rejected earlier by the caller).
    private static func firstHeredocOperator(in script: String) -> Range<String.Index>? {
        let chars = Array(script)
        var i = 0
        var quote: Character? = nil
        while i < chars.count {
            let ch = chars[i]
            if let q = quote {
                if ch == q { quote = nil }
                i += 1
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; i += 1; continue }
            if ch == "<", i + 1 < chars.count, chars[i + 1] == "<" {
                // Reject here-strings (`<<<`).
                if i + 2 < chars.count, chars[i + 2] == "<" { return nil }
                let lower = script.index(script.startIndex, offsetBy: i)
                let upper = script.index(lower, offsetBy: 2)
                return lower..<upper
            }
            i += 1
        }
        return nil
    }

    // MARK: – Approval-cache canonicalization -----------------------------------

    /// Canonical-key prefixes mirroring upstream
    /// `core/src/command_canonicalization.rs:5-6`.
    private static let canonicalBashScriptPrefix = "__codex_shell_script__"
    private static let canonicalPowershellScriptPrefix = "__codex_powershell_script__"

    /// PowerShell wrapper flags accepted before `-Command`/`-c`. Mirrors
    /// `shell-command/src/powershell.rs:9` `POWERSHELL_FLAGS` (lowercased).
    private static let powershellFlags: Set<String> = [
        "-nologo", "-noprofile", "-command", "-c",
    ]

    /// Mirrors upstream `detect_shell_type`
    /// (`shell-command/src/shell_detect.rs:13-32`): match on the full path
    /// string for the recognised shell names, otherwise recurse on the file
    /// stem (the basename with any extension stripped). Only the shell types
    /// the canonicalizer cares about are modelled here.
    private enum ShellKind { case zsh, sh, bash, powershell }

    private static func detectShellType(_ shellPath: String) -> ShellKind? {
        switch shellPath {
        case "zsh": return .zsh
        case "sh": return .sh
        case "bash": return .bash
        case "pwsh", "powershell": return .powershell
        default:
            // file_stem: basename without its extension.
            let base = (shellPath as NSString).lastPathComponent
            let stem = (base as NSString).deletingPathExtension
            // Recurse only when the stem differs from the original path,
            // matching upstream's `shell_name_path != Path::new(shell_path)`
            // guard (prevents infinite recursion).
            if stem != shellPath {
                return detectShellType(stem)
            }
            return nil
        }
    }

    /// Mirrors upstream `extract_bash_command`
    /// (`shell-command/src/bash.rs:97-110`): returns the `(shell, script)` pair
    /// when `command` is a 3-element `[shell, "-lc"|"-c", script]` invocation of
    /// a recognised bash/zsh/sh shell.
    static func extractBashCommand(_ command: [String]) -> (shell: String, script: String)? {
        guard command.count == 3 else { return nil }
        let shell = command[0]
        let flag = command[1]
        let script = command[2]
        guard flag == "-lc" || flag == "-c" else { return nil }
        switch detectShellType(shell) {
        case .zsh, .bash, .sh: return (shell, script)
        default: return nil
        }
    }

    /// Mirrors upstream `extract_powershell_command`
    /// (`shell-command/src/powershell.rs:42-70`): returns the `(shell, script)`
    /// pair when `command` is a PowerShell invocation whose flags up to and
    /// including `-Command`/`-c` are all recognised PowerShell flags.
    static func extractPowershellCommand(_ command: [String]) -> (shell: String, script: String)? {
        guard command.count >= 3 else { return nil }
        let shell = command[0]
        guard detectShellType(shell) == .powershell else { return nil }
        var i = 1
        while i + 1 < command.count {
            let flag = command[i].lowercased()
            // Reject unknown flags (matches upstream early return).
            guard powershellFlags.contains(flag) else { return nil }
            if flag == "-command" || flag == "-c" {
                return (shell, command[i + 1])
            }
            i += 1
        }
        return nil
    }

    /// Canonicalize command argv for approval-cache matching, mirroring upstream
    /// `canonicalize_command_for_approval`
    /// (`core/src/command_canonicalization.rs:14-38`).
    ///
    /// - A plain word-only single `shell -lc "<cmd>"` invocation collapses to the
    ///   inner argv (so `/bin/bash -lc 'cargo test'` and `bash -lc 'cargo   test'`
    ///   both canonicalize to `["cargo", "test"]`).
    /// - A more complex bash/zsh/sh script (here-docs, multiple commands, etc.)
    ///   collapses to `["__codex_shell_script__", <shell_mode>, <script>]`, where
    ///   `shell_mode` is the original flag (`command[1]`) so the key is stable
    ///   across wrapper-path spellings while preserving the exact script text.
    /// - A PowerShell wrapper collapses to `["__codex_powershell_script__", <script>]`.
    /// - Anything else is returned verbatim.
    public static func canonicalizeCommandForApproval(_ command: [String]) -> [String] {
        if let commands = parseShellLcPlainCommands(command), commands.count == 1 {
            return commands[0]
        }
        if let (_, script) = extractBashCommand(command) {
            let shellMode = command.count > 1 ? command[1] : ""
            return [canonicalBashScriptPrefix, shellMode, script]
        }
        if let (_, script) = extractPowershellCommand(command) {
            return [canonicalPowershellScriptPrefix, script]
        }
        return command
    }

    /// True if `argv` is one of the synthetic canonical script keys produced by
    /// `canonicalizeCommandForApproval` (i.e. its first token is the bash or
    /// powershell script-prefix sentinel). Such keys are valid in-memory
    /// approval-cache keys but are NOT real command prefixes and must not be
    /// persisted as `prefix_rule(...)` lines.
    public static func isCanonicalScriptKey(_ argv: [String]) -> Bool {
        guard let first = argv.first else { return false }
        return first == canonicalBashScriptPrefix
            || first == canonicalPowershellScriptPrefix
    }

    // MARK: – Dangerous-command heuristic ---------------------------------------

    /// Mirrors upstream `is_dangerous_to_call_with_exec`
    /// (`shell-command/src/command_safety/is_dangerous_command.rs:145-157`):
    /// a single concrete argv is dangerous if it is `rm -f` / `rm -rf`, or it
    /// is `sudo <cmd>` where `<cmd>` recursively classifies as dangerous.
    ///
    /// NOTE: upstream matches `argv[1]` *exactly* against `-f` / `-rf` — it
    /// does NOT treat `--force`, `-fd`, `-rf/` (a combined token) or any
    /// other flag form as dangerous at the base case. Keep this exact.
    private static func isDangerousArgv(_ command: ArraySlice<String>) -> Bool {
        guard let first = command.first else { return false }
        switch first {
        case "rm":
            let idx = command.index(after: command.startIndex)
            guard idx < command.endIndex else { return false }
            let flag = command[idx]
            return flag == "-f" || flag == "-rf"
        case "sudo":
            // `sudo <cmd>` → classify `<cmd>` recursively.
            return isDangerousArgv(command.dropFirst())
        default:
            return false
        }
    }

    /// Top-level dangerous-command classifier. Mirrors upstream
    /// `command_might_be_dangerous`
    /// (`is_dangerous_command.rs:7-28`): flags `rm -f`/`-rf`, `sudo <dangerous>`
    /// recursively, and any inner command of a `bash -lc "<script>"` /
    /// `sh -c` / `zsh -lc` decomposition being dangerous.
    ///
    /// The Windows PowerShell path (`is_dangerous_powershell_words`) is out of
    /// scope for the POSIX port and is treated as not-dangerous, matching the
    /// `#[cfg(not(windows))]` stub upstream (`is_dangerous_command.rs:39-43`).
    public static func isDangerousCommand(argv: [String]) -> Bool {
        if argv.isEmpty { return false }
        if isDangerousArgv(argv[...]) { return true }
        // Support `bash -lc "<script>"` where ANY inner command is dangerous.
        if let inner = parseShellLcPlainCommands(argv),
           inner.contains(where: { isDangerousArgv($0[...]) }) {
            return true
        }
        return false
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
