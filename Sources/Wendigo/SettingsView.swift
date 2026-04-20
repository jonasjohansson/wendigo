import SwiftUI
import AppKit

extension Notification.Name {
    static let wendigoRestartServer = Notification.Name("wendigoRestartServer")
}

struct SettingsView: View {
    @AppStorage("wendigo.port") private var port: Int = 8443
    @AppStorage("wendigo.useTLS") private var useTLS: Bool = false
    @AppStorage("wendigo.tunnelHostname") private var tunnelHostname: String = ""
    @ObservedObject var sourceManager: SourceManager
    @State private var certStatus: CertManager.Status = .init(exists: false, notAfter: nil, subjectAltNames: [])
    @State private var generating = false
    @State private var lastError: String?

    var body: some View {
        Form {
            Section("Server") {
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("", value: $port, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onSubmit { NotificationCenter.default.post(name: .wendigoRestartServer, object: nil) }
                }
                Text("Default 8443. Avoid 9000 — some ISPs block it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Tunnel") {
                HStack {
                    Text("Hostname")
                    TextField("e.g. wendigo.jonasjohansson.se", text: $tunnelHostname)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Set to the hostname cloudflared / tailscale funnel exposes this server at. Shown alongside the LAN URL so you can copy it from one place.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Encoding") {
                let hasActive = sourceManager.mappings.contains { $0.isActive }
                HStack {
                    Text("Bitrate")
                    Spacer()
                    Picker("", selection: $sourceManager.bitrateMbps) {
                        ForEach([5, 10, 20, 30, 50], id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                    .disabled(hasActive)
                    Text("Mbps").font(.caption2).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Keyframe")
                    Spacer()
                    Picker("", selection: $sourceManager.keyframeInterval) {
                        Text("All").tag(1)
                        Text("1s").tag(60)
                        Text("2s").tag(120)
                        Text("5s").tag(300)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                    .disabled(hasActive)
                }
                if hasActive {
                    Text("Remove streams to change encoding settings")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("TLS Certificate") {
                Toggle("Enable WSS (TLS)", isOn: $useTLS)
                    .disabled(!certStatus.exists || !certStatus.isValid)
                    .onChange(of: useTLS) { _, _ in NotificationCenter.default.post(name: .wendigoRestartServer, object: nil) }

                if certStatus.exists {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(certStatus.isValid ? "Valid" : "Expired")
                            .foregroundStyle(certStatus.isValid ? .green : .red)
                    }
                    if let exp = certStatus.notAfter {
                        HStack {
                            Text("Expires")
                            Spacer()
                            Text(exp.formatted(date: .abbreviated, time: .omitted))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !certStatus.subjectAltNames.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Valid for")
                            Text(certStatus.subjectAltNames.joined(separator: ", "))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("No certificate yet. Generate one to enable WSS.")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button(certStatus.exists ? "Regenerate" : "Generate") {
                        regenerate()
                    }
                    .disabled(generating)

                    if certStatus.exists {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([CertManager.p12URL])
                        }
                    }
                    if generating {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }

                if let err = lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                Text("Cert password is \"wendigo\" (internal; never entered).")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section("Trust cert on this Mac") {
                Text("Avoids Safari / Chrome warnings when visiting the stream endpoint from this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Copy trust command") {
                    let cmd = "sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain \"\(CertManager.certURL.path)\""
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cmd, forType: .string)
                }
                .disabled(!certStatus.exists)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshStatus() }
    }

    private func refreshStatus() {
        certStatus = CertManager.currentStatus()
    }

    private func regenerate() {
        generating = true
        lastError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try CertManager.generate()
                DispatchQueue.main.async {
                    refreshStatus()
                    generating = false
                }
            } catch {
                DispatchQueue.main.async {
                    lastError = error.localizedDescription
                    generating = false
                }
            }
        }
    }
}
