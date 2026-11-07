#if os(macOS)
import Foundation

public enum ACPAuthenticationCommands {
    public static func openCodeAccountAuthArguments(version: String?, action: String = "login") -> [String] {
        if version?.trimmingCharacters(in: CharacterSet(charactersIn: "v")).hasPrefix("1.") == true {
            return ["console", action]
        }
        return ["auth", action, "opencode"]
    }

    public static func openCodeAccountAuthCommand(argv: [String], version: String?, action: String = "login") -> [String] {
        if let version, !version.isEmpty { return argv }
        let base = Array(argv.dropLast(3))
        let script = """
        action=$1
        shift
        version=$("$@" --version) || exit $?
        case "$version" in
            1.*|v1.*) exec "$@" console "$action" ;;
            *) exec "$@" auth "$action" opencode ;;
        esac
        """
        return ["/bin/zsh", "-c", script, "rxcode-opencode-account", action] + base
    }

    public static func interactiveAuthEnvironment(_ environment: [String: String]) -> [String: String] {
        var result = environment
        for name in ["CI", "NO_COLOR", "TERM_PROGRAM", "TERM_PROGRAM_VERSION"] {
            result[name] = nil
        }
        result["TERM"] = "xterm-256color"
        result["COLORTERM"] = "truecolor"
        return result
    }

    public static func terminalLoginCommand(
        executable: String, launchArgs: [String], extraArgs: [String],
        command: String?, args: [String]
    ) -> [String] {
        guard let command else { return [executable] + launchArgs + extraArgs + args }
        if (command == "opencode" || command == "cursor-agent"), let acpIndex = launchArgs.firstIndex(of: "acp") {
            return [executable] + Array(launchArgs[..<acpIndex]) + args
        }
        // A terminal-auth hint may name the agent on PATH even when RxCode
        // installed a different version. Run the same binary used for ACP.
        let resolved = !command.contains("/") && command == URL(fileURLWithPath: executable).lastPathComponent
            ? executable : command
        return [resolved] + args
    }

    public static func openCodeLogoutCommand(executable: String, launchArgs: [String]) -> [String] {
        var command = [executable] + launchArgs
        if let acpIndex = command.firstIndex(of: "acp") {
            command = Array(command[..<acpIndex])
        }
        return command + ["auth", "logout"]
    }

    public static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
#endif
