import SwiftUI

struct NewConversationView: View {
    @EnvironmentObject private var appVM: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var peerID = ""
    @State private var isSearching = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("User ID (e.g. bob@example.com)", text: $peerID)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
                } header: {
                    Text("Find contact")
                } footer: {
                    Text("Enter the exact User ID your contact registered with.")
                }

                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        startConversation()
                    } label: {
                        HStack {
                            if isSearching {
                                ProgressView()
                            } else {
                                Text("Start Conversation")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .disabled(peerID.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                }
            }
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func startConversation() {
        let id = peerID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        isSearching = true
        error = nil

        Task {
            do {
                let bundle = try await ServerClient.shared.fetchBundle(serverID: id)
                await appVM.startConversation(with: bundle)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isSearching = false
        }
    }
}
