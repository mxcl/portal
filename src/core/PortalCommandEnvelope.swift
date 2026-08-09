import Foundation

public enum PortalCommandEnvelope {
    public static func shellScript(
        for command: String,
        exitsShellAfterCompletion: Bool = false
    ) -> String {
        let encoded = Data(command.utf8).base64EncodedString()
        let exit = exitsShellAfterCompletion ? "; exit \"$__portal_status\"" : ""
        return "\u{15}__portal_cmd=\(quote(command)); __portal_command_b64=\(quote(encoded)); printf '\\033]133;C;%s\\a' \"$__portal_command_b64\"; eval \"$__portal_cmd\"; __portal_status=$?; printf '\\033]133;P;%s\\a' \"$(pwd | base64)\"; printf '\\033]133;D;%s\\a' \"$__portal_status\"\(exit)\n"
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
