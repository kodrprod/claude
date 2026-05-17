import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var appVM: AppViewModel
    let conversation: Conversation

    @State private var messageText = ""
    @State private var messages: [Message] = []
    @State private var isSending = false
    @State private var highSecurity = false
    @State private var showingSafetyNumber = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Message list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(messages) { msg in
                            MessageBubble(message: msg)
                                .id(msg.id)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
                .onChange(of: messages.count) {
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            // Input bar
            inputBar
        }
        .navigationTitle(conversation.peerDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSafetyNumber = true
                } label: {
                    Image(systemName: conversation.safetyNumberVerified
                          ? "checkmark.shield.fill"
                          : "shield")
                        .foregroundStyle(conversation.safetyNumberVerified ? .green : .secondary)
                }
            }
        }
        .sheet(isPresented: $showingSafetyNumber) {
            SafetyNumberView(conversation: conversation)
                .environmentObject(appVM)
        }
        .onAppear {
            messages = appVM.messages(for: conversation.id)
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            if highSecurity {
                Label("Extra ratchet step enabled", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 6)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    highSecurity.toggle()
                } label: {
                    Image(systemName: highSecurity ? "lock.fill" : "lock.open")
                        .foregroundStyle(highSecurity ? .orange : .secondary)
                }
                .padding(.bottom, 10)

                TextField("Message", text: $messageText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .focused($inputFocused)

                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(canSend ? .blue : .secondary)
                }
                .disabled(!canSend || isSending)
                .padding(.bottom, 8)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Send

    private var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespaces).isEmpty && !isSending
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        messageText = ""
        isSending = true

        Task {
            if let msg = await appVM.send(text: text, in: conversation.id, highSecurity: highSecurity) {
                messages.append(msg)
            }
            isSending = false
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 48) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                Text(message.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.isOutgoing ? Color.blue : Color(.systemGray5))
                    .foregroundColor(message.isOutgoing ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                HStack(spacing: 4) {
                    if message.isHighSecurity {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(message.timestamp.formatted(.dateTime.hour().minute()))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if message.isOutgoing {
                        statusIcon
                    }
                }
                .padding(.horizontal, 4)
            }

            if !message.isOutgoing { Spacer(minLength: 48) }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch message.status {
        case .sending:
            Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
        case .sent:
            Image(systemName: "checkmark").font(.caption2).foregroundStyle(.secondary)
        case .delivered:
            Image(systemName: "checkmark.circle").font(.caption2).foregroundStyle(.secondary)
        case .read:
            Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(.blue)
        case .failed:
            Image(systemName: "exclamationmark.circle").font(.caption2).foregroundStyle(.red)
        case .received:
            EmptyView()
        }
    }
}
