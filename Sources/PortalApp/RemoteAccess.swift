#if os(macOS)
import AppKit
import Foundation
import PortalDiscovery
import SwiftUI

/// All enrollment work is serialized away from the UI. No host polling or sync timer.
actor RemoteEnrollment {
    static let shared = RemoteEnrollment()
    private func run(_ executable: String, _ arguments: [String], input: String = "") throws -> String {
        let process = Process(), output = Pipe(), stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = output; process.standardError = output; process.standardInput = stdin
        try process.run()
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + 30)
        timer.setEventHandler { if process.isRunning { process.terminate() } }
        timer.resume(); defer { timer.cancel() }
        try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw DirectoryError(text.isEmpty ? "SSH timed out or failed." : text) }
        return text
    }
    private func ssh(_ alias: String, script: String) throws -> String {
        try run("/usr/bin/ssh", ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2", "--", alias, "/bin/sh -s"], input: script)
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func keyLine(token: Data, owner: String) throws -> String {
        let fields = try PortalIdentity.publicKey(token: token).split(separator: " ")
        return "\(fields[0]) \(fields[1]) portal-access-\(owner)"
    }
    func local(owner: String, address: String, enable: Bool) throws -> HostRegistration {
        let token = try ICloudKeychainRootKey().load().get()
        var host = DiscoveryHost(); host.id = owner
        host.name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        host.username = NSUserName(); host.homeDirectory = NSHomeDirectory()
        host.shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        host.address = address.isEmpty ? try vpnAddress() : address
        guard DiscoveryHost.isPrivateAddress(host.address) else { throw DirectoryError("Enter this Mac’s private VPN IP address.") }
        host.hostPublicKey = try String(contentsOfFile: "/etc/ssh/ssh_host_ed25519_key.pub", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard FileManager.default.isExecutableFile(atPath: host.helperPath) else { throw DirectoryError("Install Portal in Applications first.") }
        let record = HostRegistration(host: host, owner: owner, token: token)
        if enable {
            try authorizeLocal(line: keyLine(token: token, owner: owner), enabled: true)
        }
        if !enable {
            let authorized = try String(contentsOfFile: NSHomeDirectory() + "/.ssh/authorized_keys", encoding: .utf8)
            guard authorized.components(separatedBy: .newlines).contains(try keyLine(token: token, owner: owner)) else {
                throw DirectoryError("The Portal identity changed or its SSH authorization was removed. Enable this Mac again.")
            }
        }
        try HostDirectory().publish(record)
        return record
    }
    func disableLocal(owner: String) throws {
        try authorizeLocal(line: "portal-access-\(owner)", enabled: false)
        try HostDirectory().remove(id: owner, owner: owner)
    }
    private func authorizeLocal(line: String, enabled: Bool) throws {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("authorized_keys")
        // Refuse symlinks: never replace a managed key file or follow it elsewhere.
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw DirectoryError("~/.ssh/authorized_keys is a symbolic link; manage authorization there manually.")
        }
        let original = FileManager.default.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
        var lines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let marker = line.split(separator: " ").last.map(String.init) ?? line
        lines.removeAll { $0.split(separator: " ").last.map(String.init) == marker }
        if enabled { lines.append(line) }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func vpnAddress() throws -> String {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { throw DirectoryError("Cannot read network interfaces.") }
        defer { freeifaddrs(head) }
        var candidates: [(String, String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) || address.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: buffer), name = String(cString: entry.pointee.ifa_name)
            if DiscoveryHost.isPrivateAddress(ip) { candidates.append((name, ip)) }
        }
        if let tailscale = candidates.first(where: { $0.1.hasPrefix("100.") }) { return tailscale.1 }
        let tunnel = candidates.filter { $0.0.hasPrefix("utun") }.map(\.1)
        guard tunnel.count == 1, let address = tunnel.first else { throw DirectoryError("Enter this Mac’s VPN IP address; Portal could not choose one automatically.") }
        return address
    }
    func enroll(alias: String, owner: String) throws -> HostRegistration {
        guard SSHConfigHosts.aliases().contains(alias) else { throw DirectoryError("Add a named Host entry to ~/.ssh/config first.") }
        let token = try ICloudKeychainRootKey().load().get()
        let output = try ssh(alias, script: """
        set -eu
        test "$(uname -s)" = Linux
        helper="$HOME/.local/lib/portal/terminal/portal-session-bridge"
        if ! test -x "$helper"; then helper="$HOME/.local/lib/gitinuum/terminal/gitinuum-session-bridge"; fi
        protocols=$(printf 'PROTOCOLS\\n' | "$helper")
        case " $protocols " in *' 2 '*) ;; *) echo 'Update the Portal terminal helper first.' >&2; exit 1;; esac
        printf 'PORTAL_HOST_V1\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n' "$(hostname)" "$(id -un)" "$HOME" "${SHELL:-/bin/bash}" "$helper" "$SSH_CONNECTION"
        cat /etc/ssh/ssh_host_ed25519_key.pub
        """)
        let lines = output.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "PORTAL_HOST_V1"), lines.count > start + 7 else { throw DirectoryError("Invalid host enrollment response.") }
        var host = DiscoveryHost(); host.name = lines[start+1]; host.username = lines[start+2]
        host.homeDirectory = lines[start+3]; host.shellPath = lines[start+4]; host.helperPath = lines[start+5]
        let connection = lines[start+6].split(separator: " ")
        guard connection.count == 4, let port = Int(connection[3]), DiscoveryHost.isPrivateAddress(String(connection[2])) else {
            throw DirectoryError("This SSH entry must connect directly to a private VPN address reachable by your phone.")
        }
        host.address = String(connection[2]); host.port = port; host.hostPublicKey = lines[start+7]
        host.id = "linux-" + PortalIdentity.fingerprint(Data((host.hostPublicKey.split(separator: " ").prefix(2).joined(separator: " ") + ":" + host.username).utf8))
        let record = HostRegistration(host: host, owner: owner, token: token)
        if let existing = try HostDirectory().registrations().first(where: { $0.id == record.id }), existing.owner != owner {
            throw DirectoryError("This Linux host is already managed by another Mac.")
        }
        let key = try keyLine(token: token, owner: owner)
        _ = try ssh(alias, script: """
        set -eu
        umask 077
        mkdir -p "$HOME/.ssh"
        file="$HOME/.ssh/authorized_keys"
        test ! -L "$file"
        touch "$file"
        if ! grep -qxF -- \(Self.quote(key)) "$file"; then printf '\\n%s\\n' \(Self.quote(key)) >> "$file"; fi
        chmod 600 "$file"
        """)
        try HostDirectory().publish(record)
        return record
    }
    func disableLinux(_ record: HostRegistration, alias: String, owner: String) throws {
        guard record.owner == owner else { throw DirectoryError("Disable this host on its enrolling Mac.") }
        _ = try ssh(alias, script: """
        set -eu
        umask 077
        file="$HOME/.ssh/authorized_keys"
        test ! -L "$file"
        temp=$(mktemp "$HOME/.ssh/portal-keys.XXXXXX")
        trap 'rm -f "$temp"' EXIT
        awk \(Self.quote("$NF != \"portal-access-" + owner + "\"")) "$file" > "$temp"
        cat "$temp" > "$file"
        """)
        try HostDirectory().remove(id: record.id, owner: owner)
    }
}

/// Enumerate literal entries for the picker; OpenSSH still interprets all connection options.
enum SSHConfigHosts {
    static func aliases() -> [String] {
        var visited = Set<String>(), names = Set<String>()
        func read(_ path: String) {
            guard visited.insert(path).inserted, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            for line in text.components(separatedBy: .newlines) {
                let fields = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].split(whereSeparator: \.isWhitespace).map(String.init)
                guard let directive = fields.first?.lowercased() else { continue }
                if directive == "host" {
                    for name in fields.dropFirst() where !name.contains(where: { "*?!".contains($0) }) { names.insert(name) }
                } else if directive == "include" {
                    for pattern in fields.dropFirst() {
                        let expanded = (pattern as NSString).expandingTildeInPath
                        let absolute = expanded.hasPrefix("/") ? expanded : NSHomeDirectory() + "/.ssh/" + expanded
                        var matches = glob_t()
                        if glob(absolute, 0, nil, &matches) == 0, let paths = matches.gl_pathv {
                            for index in 0..<Int(matches.gl_pathc) { if let path = paths[index] { read(String(cString: path)) } }
                        }
                        globfree(&matches)
                    }
                }
            }
        }
        read(NSHomeDirectory() + "/.ssh/config")
        return names.sorted()
    }
}

@MainActor
final class RemoteAccessModel: ObservableObject {
    @Published var records: [HostRegistration] = []
    @Published var status = ""
    @Published var busy = false
    @Published var address = UserDefaults.standard.string(forKey: "portal-vpn-address") ?? ""
    @Published var enabled = UserDefaults.standard.bool(forKey: "portal-remote-enabled")
    let owner: String
    var aliases: [String] { SSHConfigHosts.aliases() }
    private var linuxAliases: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "portal-linux-enrollment") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "portal-linux-enrollment") }
    }
    init() {
        owner = UserDefaults.standard.string(forKey: "portal-discovery-id") ?? UUID().uuidString
        UserDefaults.standard.set(owner, forKey: "portal-discovery-id")
    }
    /// Explicit deployment/smoke-test actions run inside the signed app, with its Keychain identity.
    func launch() async {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--enable-remote-access") { await enable() }
        else { await refresh() }
        if let index = arguments.firstIndex(of: "--enroll-ssh-host"), arguments.indices.contains(index + 1) {
            await enroll(arguments[index + 1])
        }
        if arguments.contains("--remote-access-status") {
            let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("dev.mxcl.portal/remote-access-status.json")
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let result: [String: Any] = ["enabled": enabled, "status": status,
                    "hasIdentity": (try? ICloudKeychainRootKey().load().get()) != nil,
                    "hosts": records.map { ["name": $0.host.name, "address": $0.host.address, "id": $0.id] }]
                try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: url, options: .atomic)
            } catch { NSLog("Remote access status: %@", error.localizedDescription) }
        }
    }
    func refresh() async {
        await perform {
            if self.enabled { _ = try await RemoteEnrollment.shared.local(owner: self.owner, address: self.address, enable: false) }
            self.records = try HostDirectory().registrations()
        }
    }
    func enable() async {
        await perform {
            _ = try await RemoteEnrollment.shared.local(owner: self.owner, address: self.address, enable: true)
            UserDefaults.standard.set(self.address, forKey: "portal-vpn-address")
            UserDefaults.standard.set(true, forKey: "portal-remote-enabled"); self.enabled = true
            self.records = try HostDirectory().registrations()
            self.status = "Enabled. Remote Login and your VPN must be available to connect."
        }
    }
    func enroll(_ alias: String) async {
        await perform {
            let record = try await RemoteEnrollment.shared.enroll(alias: alias, owner: self.owner)
            self.linuxAliases[record.id] = alias
            self.records = try HostDirectory().registrations()
            self.status = "Enabled \(record.host.name). Refresh Portal on your phone after iCloud syncs."
        }
    }
    func disable(_ record: HostRegistration) async {
        await perform {
            if record.id == self.owner {
                try await RemoteEnrollment.shared.disableLocal(owner: self.owner)
                UserDefaults.standard.set(false, forKey: "portal-remote-enabled"); self.enabled = false
            } else if let alias = self.linuxAliases[record.id] {
                try await RemoteEnrollment.shared.disableLinux(record, alias: alias, owner: self.owner)
                self.linuxAliases.removeValue(forKey: record.id)
            } else { throw DirectoryError("Use the Mac that enrolled this host to disable it.") }
            self.records = try HostDirectory().registrations()
        }
    }
    func createIdentity() async {
        await perform { _ = try ICloudKeychainRootKey().loadOrCreate(); self.status = "Identity ready. Allow iCloud Keychain to sync before enabling your other devices." }
    }
    private func perform(_ operation: () async throws -> Void) async {
        guard !busy else { return }; busy = true; status = ""
        defer { busy = false }
        do { try await operation() } catch { status = error.localizedDescription }
    }
}

struct RemoteAccessSettings: View {
    @ObservedObject var model: RemoteAccessModel
    @State private var alias = ""
    @State private var creatingIdentity = false
    var body: some View {
        Form {
            Section("This Mac") {
                Text("Use the same Apple Account and iCloud Keychain on your Macs and iPhone. Enable Remote Login in System Settings and connect each device to your VPN.")
                TextField("VPN IP (automatic for Tailscale)", text: $model.address)
                Button(model.enabled ? "Update This Mac" : "Enable This Mac") { Task { await model.enable() } }
                Text("Enabling authorizes your shared Portal identity to open shells as your Mac user.").foregroundStyle(.secondary)
            }
            Section("Linux Hosts") {
                Picker("SSH configuration entry", selection: $alias) {
                    Text("Choose a host").tag("")
                    ForEach(model.aliases, id: \.self) { Text($0).tag($0) }
                }
                Button("Enable Linux Host") { Task { await model.enroll(alias) } }.disabled(alias.isEmpty)
                Text("Requires a trusted ~/.ssh/config entry, an installed Portal terminal helper, and a direct VPN address. Enrollment is saved; hosts are checked only when you connect or refresh.").foregroundStyle(.secondary)
            }
            Section("Discovered Hosts") {
                ForEach(model.records) { record in
                    HStack {
                        VStack(alignment: .leading) { Text(record.host.name); Text(record.host.address).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if record.owner == model.owner { Button("Disable") { Task { await model.disable(record) } } }
                    }
                }
                Button("Refresh") { Task { await model.refresh() } }
                Text("Refresh reads the locally synced directory. iCloud may take time to deliver changes. Listed hosts may be offline.").foregroundStyle(.secondary)
            }
            Section("First Device") {
                Button("Create Shared Identity…") { creatingIdentity = true }
                Text("Only use this on your first device. If you already use Portal on another device, wait for its token to sync.").foregroundStyle(.secondary)
            }
            if !model.status.isEmpty { Text(model.status).textSelection(.enabled) }
        }
        .formStyle(.grouped).disabled(model.busy)
        .task { await model.refresh() }
        .confirmationDialog("Create an identity only if this is your first Portal device?", isPresented: $creatingIdentity) {
            Button("Create Shared Identity") { Task { await model.createIdentity() } }
        }
    }
}
#endif
