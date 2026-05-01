import AVFoundation
import Speech
import SwiftUI

struct ChatView: View {
    @EnvironmentObject var vm: ChatViewModel
    @EnvironmentObject var identityVM: IdentityViewModel
    @StateObject private var voice = VoiceInputManager()

    @State private var voicePrefix: String = ""
    @State private var micPulse: Bool = false

    var agentName: String { identityVM.identity?.agentName.isEmpty == false ? identityVM.identity!.agentName : "—" }
    var dayCount: Int { identityVM.identity?.daysWithUser ?? 0 }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.cinBg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().overlay(Color.cinFg)
                messageList
            }
            inputBar
        }
        .onAppear { vm.startPolling() }
        .onDisappear { voice.stop() }
        .onChange(of: voice.liveTranscript) { text in
            guard !text.isEmpty else { return }
            vm.inputText = voicePrefix + text
        }
        .onChange(of: voice.isRecording) { recording in
            if recording {
                withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) {
                    micPulse = true
                }
            } else {
                withAnimation(.default) { micPulse = false }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text(agentName)
                    .font(.newsreader(size: 22))
                    .foregroundStyle(Color.cinAccent1)
                Text("HERE · DAY \(dayCount)")
                    .font(.dmMono(size: 9))
                    .foregroundStyle(Color.cinSub)
                    .kerning(1.8)
            }
            Spacer()
            Text("···")
                .font(.dmMono(size: 12))
                .foregroundStyle(Color.cinSub)
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(vm.messages.enumerated()), id: \.element.id) { idx, msg in
                        Group {
                            if msg.isFromAgent && msg.isProactive {
                                ProactiveDivider(date: msg.date)
                            }
                            CinMessageBubble(message: msg, agentName: agentName)
                                .id(msg.id)
                        }
                    }
                    if vm.isWaitingForReply {
                        CinTypingIndicator(agentName: agentName)
                            .id("__typing__")
                    }
                    Color.clear.frame(height: 88)  // clearance for input bar
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
            }
            .background(Color.cinBg)
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { dismissKeyboard() }
            .onChange(of: vm.messages.count) { _ in scrollToBottom(proxy) }
            .onChange(of: vm.isWaitingForReply) { _ in
                if vm.isWaitingForReply { scrollToBottom(proxy) }
            }
            .onAppear { scrollToBottom(proxy, animated: false) }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.cinLine).frame(height: 1)
            HStack(alignment: .bottom, spacing: 0) {
                // Mic button
                Button {
                    if voice.isRecording {
                        voice.stop()
                    } else {
                        voicePrefix = vm.inputText.isEmpty ? "" : vm.inputText + " "
                        dismissKeyboard()
                        voice.start()
                    }
                } label: {
                    Image(systemName: voice.isRecording ? "mic.fill" : "mic")
                        .font(.system(size: 15, weight: voice.isRecording ? .medium : .light))
                        .foregroundStyle(voice.isRecording ? Color.cinAccent1 : Color.cinSub)
                        .opacity(voice.isRecording && micPulse ? 0.35 : 1.0)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)

                Rectangle().fill(Color.cinLine).frame(width: 1, height: 18).padding(.horizontal, 8)

                TextField("", text: $vm.inputText, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.notoSerifSC(size: 13))
                    .foregroundStyle(Color.cinFg)
                    .tint(Color.cinAccent1)
                    .placeholder(when: vm.inputText.isEmpty) {
                        Text(voice.isRecording ? "正在听…" : "给 \(agentName) 写点什么…")
                            .font(.notoSerifSC(size: 13, weight: .regular))
                            .italic()
                            .foregroundStyle(Color.cinSub)
                    }
                    .submitLabel(.send)
                    .onSubmit { Task { await vm.sendMessage() } }
                    .frame(maxWidth: .infinity)

                Button {
                    Task { await vm.sendMessage() }
                } label: {
                    Text("SEND")
                        .font(.dmMono(size: 9, weight: .medium))
                        .kerning(2.5)
                        .foregroundStyle(Color.cinBg)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(
                            vm.inputText.trimmingCharacters(in: .whitespaces).isEmpty
                                ? Color.cinSub : Color.cinAccent1
                        )
                }
                .disabled(vm.inputText.trimmingCharacters(in: .whitespaces).isEmpty || vm.isSending)
                .padding(.leading, 10)
            }
            .padding(.horizontal, 16)
            .padding(.top, 11)
            .padding(.bottom, 28)
            .background(Color(hex: "#fbf7ec"))
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let target = vm.isWaitingForReply ? "__typing__" : vm.messages.last?.id
        guard let target else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .bottom) }
        } else {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }
}

// MARK: - Proactive divider

private struct ProactiveDivider: View {
    let date: Date

    private var timeString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.cinLine).frame(height: 0.5)
            Text("SHE REACHED OUT · \(timeString)")
                .font(.dmMono(size: 8.5))
                .foregroundStyle(Color.cinSub)
                .kerning(2)
                .fixedSize()
            Rectangle().fill(Color.cinLine).frame(height: 0.5)
        }
        .padding(.vertical, 14)
    }
}

// MARK: - Message bubble

struct CinMessageBubble: View {
    let message: ChatMessage
    let agentName: String

    var body: some View {
        if message.isFromAgent {
            agentBubble
        } else {
            userBubble
        }
    }

    private var agentBubble: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(agentName.uppercased())
                    .font(.dmMono(size: 8.5))
                    .foregroundStyle(Color.cinAccent1)
                    .kerning(2.5)
                Spacer()
            }
            .padding(.bottom, 5)
            .padding(.leading, 2)

            Text(message.content)
                .font(.notoSerifSC(size: 13.5))
                .foregroundStyle(Color.cinFg)
                .lineSpacing(4)
                .padding(.horizontal, 15)
                .padding(.vertical, 12)
                .frame(maxWidth: UIScreen.main.bounds.width * 0.82, alignment: .leading)
                .background(Color.cinAccent1Soft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 14)
    }

    private var userBubble: some View {
        HStack(spacing: 0) {
            Spacer(minLength: UIScreen.main.bounds.width * 0.22)
            VStack(alignment: .trailing, spacing: 4) {
                Text(message.content)
                    .font(.notoSerifSC(size: 13.5))
                    .foregroundStyle(Color.cinBg)
                    .lineSpacing(4)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 12)
                    .background(Color.cinAccent2)
                Text(message.date, style: .time)
                    .font(.dmMono(size: 8))
                    .foregroundStyle(Color.cinSub)
                    .kerning(1.5)
                    .padding(.trailing, 2)
            }
        }
        .padding(.bottom, 14)
    }
}

// MARK: - Typing indicator

struct CinTypingIndicator: View {
    let agentName: String
    @State private var phase: Int = 0
    @State private var tickerTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(agentName.uppercased())
                .font(.dmMono(size: 8.5))
                .foregroundStyle(Color.cinAccent1)
                .kerning(2.5)
                .padding(.leading, 2)
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(phase == i ? Color.cinAccent1 : Color.cinLine)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .background(Color.cinAccent1Soft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 14)
        .onAppear {
            tickerTask?.cancel()
            tickerTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled else { break }
                    phase = (phase + 1) % 3
                }
            }
        }
        .onDisappear { tickerTask?.cancel(); tickerTask = nil }
    }
}

// MARK: - Placeholder helper

extension View {
    @ViewBuilder
    func placeholder<Content: View>(when show: Bool, @ViewBuilder placeholder: () -> Content) -> some View {
        ZStack(alignment: .leading) {
            if show { placeholder() }
            self
        }
    }
}

// MARK: - Voice Input Manager

final class VoiceInputManager: ObservableObject {
    @Published var isRecording = false
    @Published var liveTranscript = ""

    private let recognizer: SFSpeechRecognizer? =
        SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) ?? SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()

    func start() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else { return }
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                guard granted else { return }
                DispatchQueue.main.async { self?.beginSession() }
            }
        }
    }

    private func beginSession() {
        task?.cancel(); task = nil
        liveTranscript = ""

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch { return }

        request = SFSpeechAudioBufferRecognitionRequest()
        request?.shouldReportPartialResults = true
        guard let request, let recognizer else { return }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result {
                DispatchQueue.main.async {
                    self?.liveTranscript = result.bestTranscription.formattedString
                }
            }
            if error != nil || result?.isFinal == true {
                DispatchQueue.main.async { self?.stop() }
            }
        }

        let node = engine.inputNode
        node.installTap(onBus: 0, bufferSize: 1024, format: node.outputFormat(forBus: 0)) { [weak self] buf, _ in
            self?.request?.append(buf)
        }

        engine.prepare()
        do {
            try engine.start()
            DispatchQueue.main.async { self.isRecording = true }
        } catch {
            cleanUp()
        }
    }

    func stop() {
        engine.stop()
        if engine.inputNode.numberOfInputs > 0 {
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        request = nil
        task?.cancel(); task = nil
        isRecording = false
        liveTranscript = ""
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func cleanUp() {
        request = nil; task = nil; isRecording = false; liveTranscript = ""
    }
}
