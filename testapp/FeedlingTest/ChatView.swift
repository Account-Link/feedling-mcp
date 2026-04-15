import SwiftUI

struct ChatView: View {
    @EnvironmentObject var vm: ChatViewModel

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()
                VStack(spacing: 0) {
                    messageList
                    inputBar
                }
            }
            .navigationTitle("OpenClaw")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(white: 0.07), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .onAppear { vm.startPolling() }
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(vm.messages) { msg in
                        MessageBubble(message: msg)
                            .id(msg.id)
                    }
                    if vm.isWaitingForReply {
                        TypingIndicator()
                            .id("__typing__")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            .background(Color.black)
            .onChange(of: vm.messages.count) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: vm.isWaitingForReply) { _ in
                if vm.isWaitingForReply { scrollToBottom(proxy) }
            }
            .onAppear {
                scrollToBottom(proxy, animated: false)
            }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("给 OpenClaw 发消息…", text: $vm.inputText, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(white: 0.14))
                .foregroundStyle(.white)
                .tint(.cyan)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .submitLabel(.send)
                .onSubmit {
                    Task { await vm.sendMessage() }
                }

            Button {
                Task { await vm.sendMessage() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(vm.inputText.trimmingCharacters(in: .whitespaces).isEmpty
                                     ? Color(white: 0.3) : .cyan)
            }
            .disabled(vm.inputText.trimmingCharacters(in: .whitespaces).isEmpty || vm.isSending)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .background(Color(white: 0.07))
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let anchor: UnitPoint = .bottom
        if vm.isWaitingForReply {
            if animated {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("__typing__", anchor: anchor) }
            } else {
                proxy.scrollTo("__typing__", anchor: anchor)
            }
        } else if let last = vm.messages.last {
            if animated {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last.id, anchor: anchor) }
            } else {
                proxy.scrollTo(last.id, anchor: anchor)
            }
        }
    }
}

// MARK: - MessageBubble

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if message.isFromOpenClaw {
                bubbleContent
                Spacer(minLength: 56)
            } else {
                Spacer(minLength: 56)
                bubbleContent
            }
        }
    }

    private var bubbleContent: some View {
        VStack(alignment: message.isFromOpenClaw ? .leading : .trailing, spacing: 4) {

            // Sender label (OpenClaw only)
            if message.isFromOpenClaw {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.cyan)
                    Text("OpenClaw")
                        .font(.caption2.bold())
                        .foregroundStyle(.cyan)
                    if message.isFromLiveActivity {
                        Text("· Dynamic Island")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                .padding(.leading, 4)
            }

            // Bubble
            Text(message.content)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(message.isFromOpenClaw
                             ? Color(white: 0.16)
                             : Color.cyan.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: 18))

            // Timestamp
            Text(message.date, style: .time)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.25))
                .padding(.horizontal, 4)
        }
    }
}

// MARK: - TypingIndicator

struct TypingIndicator: View {
    @State private var phase: Int = 0

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.white.opacity(phase == i ? 0.8 : 0.25))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Color(white: 0.16))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            Spacer(minLength: 56)
        }
        .onAppear {
            withAnimation(.linear(duration: 0.5).repeatForever(autoreverses: false)) {
                phase = (phase + 1) % 3
            }
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                phase = (phase + 1) % 3
            }
        }
    }
}
