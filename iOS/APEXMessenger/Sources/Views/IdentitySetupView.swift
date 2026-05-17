import SwiftUI

struct IdentitySetupView: View {
    @EnvironmentObject private var appVM: AppViewModel
    @State private var displayName = ""
    @State private var serverID = ""
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.blue)

                VStack(spacing: 8) {
                    Text("APEX Messenger")
                        .font(.largeTitle.bold())
                    Text("End-to-end encrypted · Post-quantum secure")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 16) {
                    TextField("Display name", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()

                    TextField("User ID (e.g. alice@example.com)", text: $serverID)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
                }
                .padding(.horizontal)

                Button {
                    isCreating = true
                    Task {
                        await appVM.createIdentity(serverID: serverID, displayName: displayName)
                        isCreating = false
                    }
                } label: {
                    HStack {
                        if isCreating {
                            ProgressView().tint(.white)
                        } else {
                            Text("Create Identity")
                                .bold()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(canCreate ? Color.blue : Color.gray)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!canCreate || isCreating)
                .padding(.horizontal)

                if let error = appVM.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                        .padding(.horizontal)
                }

                Spacer()

                Text("Your cryptographic keys are generated locally\nand never leave this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom)
            }
            .navigationTitle("")
            .navigationBarHidden(true)
        }
    }

    private var canCreate: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !serverID.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

#Preview {
    IdentitySetupView()
        .environmentObject(AppViewModel())
}
