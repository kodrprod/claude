import SwiftUI

struct SafetyNumberView: View {
    @EnvironmentObject private var appVM: AppViewModel
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation

    @State private var confirmed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.blue)

                    VStack(spacing: 8) {
                        Text("Safety Number")
                            .font(.title2.bold())
                        Text("Verify with \(conversation.peerDisplayName) that your safety numbers match to confirm no one is intercepting your messages.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    if let sn = appVM.safetyNumber(for: conversation) {
                        safetyNumberGrid(sn)
                    } else {
                        Text("Safety number unavailable")
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 12) {
                        if conversation.safetyNumberVerified {
                            Label("Verified", systemImage: "checkmark.shield.fill")
                                .foregroundStyle(.green)
                                .font(.headline)
                        } else {
                            Button {
                                appVM.markVerified(conversation.id)
                                confirmed = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                    dismiss()
                                }
                            } label: {
                                Label(confirmed ? "Verified!" : "Mark as Verified",
                                      systemImage: confirmed ? "checkmark.shield.fill" : "checkmark.shield")
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(confirmed ? Color.green : Color.blue)
                                    .foregroundColor(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .disabled(confirmed)
                        }
                    }
                    .padding(.horizontal)

                    Text("Only mark as verified after comparing the numbers in person or via a separate trusted channel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding()
            }
            .navigationTitle("Verify Identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // Render the safety number as a 3×2 grid of number blocks
    private func safetyNumberGrid(_ sn: String) -> some View {
        let groups = sn.split(separator: " ").map(String.init)
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible()), count: 3),
            spacing: 12
        ) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                Text(group)
                    .font(.system(.title3, design: .monospaced).bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal)
    }
}
