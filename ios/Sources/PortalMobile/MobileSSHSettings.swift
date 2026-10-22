#if os(iOS)
import SwiftUI
import PortalMobileCore

struct MobileSSHSettings: View {
    let model: MobileRemoteModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: SSHHost?
    @State private var publicKey = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Connect your iPhone and Mac to Tailscale or another private VPN. Enable Remote Login on the Mac. Portal connects directly over SSH; no subscription is required.")
                }
                Section("Macs") {
                    ForEach(model.hosts) { host in
                        Button(host.name) { editing = host }
                    }
                    .onDelete { offsets in
                        model.hosts.remove(atOffsets: offsets)
                        do { try model.saveHosts() } catch { self.error = error.localizedDescription }
                    }
                    Button("Add Mac", systemImage: "plus") { editing = SSHHost() }
                }
                Section("Authorize this iPhone") {
                    Text("Your authentication token stays in iCloud Keychain. Add this derived public key to ~/.ssh/authorized_keys on each Mac. Keep the token private.")
                    if !publicKey.isEmpty {
                        ShareLink("Share SSH Public Key", item: publicKey)
                        Text(publicKey).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("SSH over VPN")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                do { publicKey = try SSHIdentity.publicKey() }
                catch { self.error = error.localizedDescription }
            }
            .sheet(item: $editing) { host in
                SSHHostEditor(host: host) { updated in
                    if let index = model.hosts.firstIndex(where: { $0.id == updated.id }) {
                        model.hosts[index] = updated
                    } else { model.hosts.append(updated) }
                    try model.saveHosts()
                }
            }
            .onDisappear { Task { await model.refreshCatalog() } }
        }
    }
}

private struct SSHHostEditor: View {
    @State var host: SSHHost
    let save: (SSHHost) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Name", text: $host.name)
                    TextField("VPN IP address", text: $host.address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("SSH username", text: $host.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Port", value: $host.port, format: .number.grouping(.never)).keyboardType(.numberPad)
                }
                Section {
                    TextField("ssh-ed25519 AAAA…", text: $host.hostPublicKey, axis: .vertical)
                        .font(.caption.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("On the Mac, copy /etc/ssh/ssh_host_ed25519_key.pub using a trusted connection. Portal rejects servers whose host key does not match.")
                        .font(.footnote)
                } header: { Text("Mac’s SSH public host key") }
                Section("Paths on the Mac") {
                    TextField("Home directory, e.g. /Users/max", text: $host.homeDirectory)
                    TextField("Portal session helper", text: $host.helperPath)
                    TextField("Shell", text: $host.shellPath)
                }
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Mac Connection")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try host.validate()
                            try save(host)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }
}
#endif
