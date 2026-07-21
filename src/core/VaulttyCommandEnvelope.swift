import Foundation

public enum VaulttyCommandEnvelope {
    public static func shellScript(for command: String) -> String {
        let encoded = Data(command.utf8).base64EncodedString()
        return "\u{15}__vaultty_cmd=\(quote(command)); __vaultty_command_b64=\(quote(encoded)); printf '\\033]133;C;%s\\a' \"$__vaultty_command_b64\"; eval \"$__vaultty_cmd\"; __vaultty_status=$?; printf '\\033]133;P;%s\\a' \"$(pwd | base64)\"; printf '\\033]133;D;%s\\a' \"$__vaultty_status\"\n"
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
