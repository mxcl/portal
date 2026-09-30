#if os(macOS)
import Foundation

public enum PortalCommandEnvelope {
    /// Portal supplies the command editor; shell line editors redraw our private envelope.
    public static let inputSetupScript = """
        if [ -n "${ZSH_VERSION-}" ]; then
            unsetopt zle
        elif [ -n "${BASH_VERSION-}" ]; then
            set +o emacs
            set +o vi
        fi
        stty -echo
        """

    // Acknowledge the short bootstrap before sending the longer startup script.
    static let shellBootstrapScript = inputSetupScript + "\nprintf '\\033]133;R;\\a'\n"

    public static func shellScript(
        for command: String,
        exitsShellAfterCompletion: Bool = false
    ) -> String {
        let encoded = Data(command.utf8).base64EncodedString()
        let exit = exitsShellAfterCompletion ? "; exit \"$__portal_status\"" : ""
        // Sessions outlive app upgrades, and commands can re-enable the shell editor.
        // Hide the envelope, but let commands (including SSH) inherit normal input echo.
        return "\u{15}\(inputSetupScript)\n__portal_cmd=\(quote(command)); __portal_command_b64=\(quote(encoded)); printf '\\033]133;C;%s\\a' \"$__portal_command_b64\"; stty echo 2>/dev/null; eval \"$__portal_cmd\"; __portal_status=$?; stty -echo 2>/dev/null; printf '\\033]133;P;%s\\a' \"$(pwd | base64)\"; __portal_typeahead_b64=''; if __portal_tty_state=$(stty -g 2>/dev/null); then __portal_typeahead_b64=$( (stty -icanon min 0 time 0 2>/dev/null; dd bs=65536 count=1 2>/dev/null; stty \"$__portal_tty_state\" 2>/dev/null) | base64 | tr -d '\\n'); fi; if [ -n \"$__portal_typeahead_b64\" ]; then printf '\\033]133;I;%s\\a' \"$__portal_typeahead_b64\"; fi; printf '\\033]133;D;%s\\a' \"$__portal_status\"\(exit)\n"
    }

    private static func quote(_ value: String) -> String {
        // Cooked PTYs have a bounded input line. Continue quoted chunks without changing the value.
        let scalars = Array(value.unicodeScalars)
        guard !scalars.isEmpty else { return "''" }
        return stride(from: 0, to: scalars.count, by: 128).map { start in
            let chunk = String(String.UnicodeScalarView(scalars[start..<min(start + 128, scalars.count)]))
            return "'" + chunk.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: "\\\n")
    }
}

#endif
