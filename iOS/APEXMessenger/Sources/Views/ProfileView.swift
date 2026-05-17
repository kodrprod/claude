import SwiftUI
import APEX

struct ProfileView: View {
    @EnvironmentObject private var appVM: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Your Identity") {
                    if let stored = appVM.storedIdentity {
                        LabeledContent("Display name", value: stored.displayName)
                        LabeledContent("User ID", value: stored.serverID)
                        LabeledContent("Registration ID", value: "\(stored.registrationID)")
                    }
                }

                Section("Your Key Fingerprint") {
                    if let stored = appVM.storedIdentity {
                        Text(stored.identityKeyData.hexString)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Section("Protocol") {
                    LabeledContent("Version", value: APEX.version)
                    LabeledContent("Post-Quantum", value: APEX.isPostQuantumAvailable ? "ML-KEM-768 active" : "Fallback (classical)")
                    LabeledContent("Secure Enclave", value: APEX.isSecureEnclaveAvailable ? "Available" : "Not available")
                }

                Section {
                    Button("Share My Bundle", systemImage: "square.and.arrow.up") {
                        shareBundle()
                    }
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func shareBundle() {
        guard let bundleData = AppStorage.shared.loadBundleData(),
              let str = String(data: bundleData, encoding: .utf8)
        else { return }

        let av = UIActivityViewController(activityItems: [str], applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController
        else { return }
        root.present(av, animated: true)
    }
}

// MARK: - Data hex helper

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
