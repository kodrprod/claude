import SwiftUI

struct ConversationListView: View {
    @EnvironmentObject private var appVM: AppViewModel
    @State private var showingNewChat = false
    @State private var showingProfile = false

    var body: some View {
        NavigationStack {
            Group {
                if appVM.conversations.isEmpty {
                    emptyState
                } else {
                    List(appVM.conversations) { conv in
                        NavigationLink(value: conv) {
                            ConversationRow(conversation: conv)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Messages")
            .navigationDestination(for: Conversation.self) { conv in
                ChatView(conversation: conv)
                    .environmentObject(appVM)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingProfile = true
                    } label: {
                        Image(systemName: "person.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNewChat = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .sheet(isPresented: $showingNewChat) {
                NewConversationView()
                    .environmentObject(appVM)
            }
            .sheet(isPresented: $showingProfile) {
                ProfileView()
                    .environmentObject(appVM)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No conversations yet")
                .font(.headline)
            Text("Tap the compose button to start\na new encrypted conversation.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

// MARK: - Conversation Row

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(avatarColor)
                .frame(width: 48, height: 48)
                .overlay(
                    Text(conversation.peerDisplayName.prefix(1).uppercased())
                        .font(.title3.bold())
                        .foregroundColor(.white)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(conversation.peerDisplayName)
                        .font(.headline)
                    Spacer()
                    Text(conversation.lastMessageDate.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text(conversation.lastMessagePreview.isEmpty
                         ? "Tap to start chatting"
                         : conversation.lastMessagePreview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)")
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue)
                            .clipShape(Capsule())
                    }

                    if conversation.safetyNumberVerified {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var avatarColor: Color {
        let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal]
        let idx = abs(conversation.peerDisplayName.hashValue) % colors.count
        return colors[idx]
    }
}
