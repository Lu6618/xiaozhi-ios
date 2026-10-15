import SwiftUI

private enum ConversationUIMode {
    case text
    case pushToTalk
    case voiceCall
}

struct ConversationView: View {
    @EnvironmentObject private var chatVM: ChatViewModel
    @StateObject private var audioMonitor = AudioVolumeMonitor()
    @StateObject private var settings = Live2DSettings.shared

    @State private var messageText = ""
    @State private var mode: ConversationUIMode = .text
    @State private var isPressingToTalk = false
    @State private var showModelSelector = false
    @State private var showServiceSettings = false
    @State private var voiceActivityStartedAt: Date?
    @State private var lastInterruptionAt = Date.distantPast
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                if mode == .text {
                    transcript
                } else {
                    voiceStage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if chatVM.isSearching {
                loadingOverlay
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
                .background(Color.white)
        }
        .fullScreenCover(isPresented: $chatVM.showCamera) {
            CameraView(
                onImageCaptured: { chatVM.processCapturedImage(base64Str: $0) },
                onCancel: { chatVM.cancelCamera() }
            )
        }
        .sheet(item: $chatVM.activeSheet) { item in
            switch item {
            case .xhsResult:
                XhsResultView(viewModel: chatVM)
            case .xhsPublish:
                XhsPublishView(
                    image: chatVM.publishDraftImage,
                    title: $chatVM.publishDraftTitle,
                    content: $chatVM.publishDraftContent,
                    onPublish: { chatVM.confirmPublish(finalImage: $0) },
                    onCancel: { chatVM.activeSheet = nil; chatVM.cancelCamera() }
                )
            case .mapResult:
                MapResultView(pois: chatVM.mapPOIs, route: chatVM.mapRoute)
            case .htmlResult:
                if let html = chatVM.generatedHtml {
                    WebResultView(htmlContent: html)
                }
            }
        }
        .sheet(isPresented: $showModelSelector) {
            ModelSelectorSheet(settings: settings)
                .presentationDetents([.height(280)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showServiceSettings) {
            ServiceSettingsSheet()
                .presentationDetents([.height(330)])
                .presentationDragIndicator(.visible)
        }
        .alert("设备等待激活", isPresented: $chatVM.showActivationAlert) {
            Button("好的") {}
        } message: {
            Text(chatVM.activationMessage)
        }
        .onChange(of: chatVM.appState) { state in
            if state == .connectionFailed || state == .awaitingActivation {
                if mode == .voiceCall { mode = .pushToTalk }
            }
        }
        .task {
            chatVM.setMode(handsFree: false)
            if !chatVM.isConnected {
                await chatVM.connect()
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("小智")
                    .font(.system(size: 24, weight: .bold))
                Text(statusText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(statusColor)
            }

            Spacer()

            Button {
                showModelSelector = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 20, weight: .medium))
                    Text(settings.currentModel.name)
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(uiColor: .systemGray6))
                .clipShape(Capsule())
            }

            Button {
                showServiceSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
                    .background(Color(uiColor: .systemGray6))
                    .clipShape(Circle())
            }

            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .blinkEffect(shouldBlink: chatVM.appState == .listening || chatVM.appState == .speaking)
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    if chatVM.messageList.isEmpty {
                        Text("你好，我是小智。有什么想聊的吗？")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .padding(.top, 18)
                    }

                    ForEach(chatVM.messageList) { message in
                        ConversationMessageRow(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
            }
            .onChange(of: chatVM.messageList.last?.text) { _ in
                guard let lastID = chatVM.messageList.last?.id else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var model: some View {
        Live2DView(
            directoryName: settings.currentModel.dir,
            jsonName: settings.currentModel.json,
            audioMonitor: audioMonitor
        )
        .id(settings.currentModel.dir)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { isComposerFocused = false }
    }

    private var voiceStage: some View {
        model
        .onChange(of: audioMonitor.volume) { volume in
            detectVoiceCallInterruption(volume: volume)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            longComposerControl

            composerCircleButton(
                icon: mode == .text ? "mic.fill" : "keyboard",
                action: mode == .text ? enterPushToTalkMode : returnToTextMode
            )

            composerCircleButton(
                icon: mode == .voiceCall ? "mic.fill" : "phone.fill",
                action: mode == .voiceCall ? switchCallToPushToTalk : beginVoiceCall
            )
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var longComposerControl: some View {
        if mode == .text {
            HStack(spacing: 8) {
                Button { chatVM.showCamera = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .medium))
                        .frame(width: 36, height: 36)
                }

                TextField("给小智发消息", text: $messageText, axis: .vertical)
                    .focused($isComposerFocused)
                    .lineLimit(1...4)
                    .submitLabel(.send)
                    .onSubmit(sendMessage)

                if !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Color.blue)
                            .clipShape(Circle())
                    }
                }
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(uiColor: .systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
            .overlay { composerBorder }
        } else if mode == .pushToTalk {
            Text(isPressingToTalk ? "松开结束" : "按住说话")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isPressingToTalk ? Color.blue : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(isPressingToTalk ? Color.blue.opacity(0.10) : Color(uiColor: .systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
                .overlay { composerBorder }
                .contentShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
                .gesture(pushToTalkGesture)
        } else {
            Button(action: endVoiceCall) {
                Text("挂断")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Color.red)
                    .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
            }
        }
    }

    private var composerBorder: some View {
        RoundedRectangle(cornerRadius: 27, style: .continuous)
            .stroke(Color(uiColor: .separator).opacity(0.45), lineWidth: 1)
    }

    private var pushToTalkGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressingToTalk else { return }
                isPressingToTalk = true
                chatVM.startUserSpeech()
            }
            .onEnded { _ in
                guard isPressingToTalk else { return }
                isPressingToTalk = false
                chatVM.stopUserSpeech()
            }
    }

    private func composerCircleButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(Color.blue)
                .clipShape(Circle())
        }
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.2).ignoresSafeArea()
            ProgressView()
                .controlSize(.large)
                .padding(26)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private var statusText: String {
        switch chatVM.appState {
        case .idle: return "在线"
        case .listening: return "正在聆听"
        case .speaking: return "正在回复"
        case .connecting: return "连接中"
        case .awaitingActivation: return "等待激活"
        case .connectionFailed: return "连接失败"
        }
    }

    private var statusColor: Color {
        switch chatVM.appState {
        case .idle: return .green
        case .listening: return .green
        case .speaking: return .blue
        case .connecting, .awaitingActivation: return .orange
        case .connectionFailed: return .red
        }
    }

    private func sendMessage() {
        let content = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        chatVM.sendTextMessage(content)
        messageText = ""
    }

    private func enterPushToTalkMode() {
        isComposerFocused = false
        mode = .pushToTalk
    }

    private func returnToTextMode() {
        leaveVoiceMode()
        mode = .text
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            isComposerFocused = true
        }
    }

    private func beginVoiceCall() {
        guard chatVM.isConnected else {
            Task { await chatVM.connect() }
            return
        }
        mode = .voiceCall
        chatVM.startRealtimeConversation()
    }

    private func endVoiceCall() {
        chatVM.stopRealtimeConversation()
        mode = .pushToTalk
    }

    private func switchCallToPushToTalk() {
        chatVM.stopRealtimeConversation()
        mode = .pushToTalk
    }

    private func leaveVoiceMode() {
        if isPressingToTalk {
            isPressingToTalk = false
            chatVM.stopUserSpeech()
        }
        if mode == .voiceCall {
            chatVM.stopRealtimeConversation()
        } else {
            chatVM.setMode(handsFree: false)
        }
    }

    private func detectVoiceCallInterruption(volume: Float) {
        guard mode == .voiceCall, chatVM.appState == .speaking else {
            voiceActivityStartedAt = nil
            return
        }

        let threshold: Float = 0.16
        if volume >= threshold {
            let now = Date()
            if voiceActivityStartedAt == nil {
                voiceActivityStartedAt = now
            }
            guard let startedAt = voiceActivityStartedAt,
                  now.timeIntervalSince(startedAt) >= 0.28,
                  now.timeIntervalSince(lastInterruptionAt) >= 1.2 else { return }

            lastInterruptionAt = now
            voiceActivityStartedAt = nil
            chatVM.interruptAssistantForVoiceCall()
        } else {
            voiceActivityStartedAt = nil
        }
    }
}

private struct ConversationMessageRow: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.type == .sent { Spacer(minLength: 52) }

            VStack(alignment: message.type == .sent ? .trailing : .leading, spacing: 4) {
                if let image = message.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 190, maxHeight: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 16))
                        .foregroundColor(message.type == .sent ? Color.white : Color.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(message.type == .sent ? Color.blue : Color(uiColor: .systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .textSelection(.enabled)
                }
            }

            if message.type == .received { Spacer(minLength: 52) }
        }
    }
}

private struct ModelSelectorSheet: View {
    @ObservedObject var settings: Live2DSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("选择人物形象")
                    .font(.title2.bold())
                Text("选择后立即切换，并在下次启动时保留。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(ALL_MODELS) { model in
                    Button {
                        settings.selectModel(model)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: settings.currentModel.id == model.id ? "checkmark.circle.fill" : "person.crop.circle")
                                .font(.system(size: 20))
                            Text(model.name)
                                .fontWeight(.semibold)
                            Spacer()
                        }
                        .foregroundColor(settings.currentModel.id == model.id ? Color.white : Color.primary)
                        .padding(.horizontal, 14)
                        .frame(height: 52)
                        .background(settings.currentModel.id == model.id ? Color.blue : Color(uiColor: .systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }

            Spacer()
        }
        .padding(22)
    }
}

private struct ServiceSettingsSheet: View {
    @AppStorage(AppConfig.visionBaseURLKey) private var visionBaseURL = ""
    @Environment(\.dismiss) private var dismiss
    @State private var draftURL = AppConfig.visionBaseURL

    private var usesLoopback: Bool {
        draftURL.contains("127.0.0.1") || draftURL.contains("localhost")
    }

    private var isValidURL: Bool {
        guard let url = URL(string: draftURL), let scheme = url.scheme else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("服务设置")
                    .font(.title2.bold())
                Text("图片识别需要部署原项目配套的视觉服务。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("视觉服务地址")
                    .font(.headline)
                TextField("例如 http://192.168.1.20:8005", text: $draftURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(12)
                    .background(Color(uiColor: .systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                if usesLoopback {
                    Label("127.0.0.1 指向当前 iPhone，无法连接电脑上的服务。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("接口路径应支持 POST /vision/analyze。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                visionBaseURL = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
                dismiss()
            } label: {
                Text("保存设置")
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .foregroundStyle(.white)
                    .background(Color.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(!isValidURL || usesLoopback)
            .opacity((isValidURL && !usesLoopback) ? 1 : 0.45)

            Spacer()
        }
        .padding(22)
    }
}

#Preview {
    ConversationView()
        .environmentObject(ChatViewModel())
}
