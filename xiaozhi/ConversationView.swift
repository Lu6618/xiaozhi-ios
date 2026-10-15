import SwiftUI
import PhotosUI
import Combine

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
    @State private var mode: ConversationUIMode = .pushToTalk
    @State private var isPressingToTalk = false
    @State private var showModelSelector = false
    @State private var showServiceSettings = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showClearHistoryConfirmation = false
    @State private var callStartedAt: Date?
    @State private var callElapsedSeconds = 0
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
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("清空全部聊天记录？", isPresented: $showClearHistoryConfirmation, titleVisibility: .visible) {
            Button("清空", role: .destructive) { chatVM.clearConversationHistory() }
            Button("取消", role: .cancel) {}
        }
        .onChange(of: selectedPhoto) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await MainActor.run { chatVM.processSelectedImage(image) }
                }
                await MainActor.run { selectedPhoto = nil }
            }
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

            Menu {
                Button { showServiceSettings = true } label: {
                    Label("服务设置", systemImage: "server.rack")
                }
                Button(role: .destructive) { showClearHistoryConfirmation = true } label: {
                    Label("清空聊天记录", systemImage: "trash")
                }
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
                        ConversationMessageRow(message: message, onRecognizeText: { image in
                            Task {
                                let text = await chatVM.recognizeText(in: image)
                                await MainActor.run {
                                    UIPasteboard.general.string = text
                                }
                            }
                        })
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
        ZStack(alignment: .top) {
            model
            if mode == .voiceCall {
                HStack(spacing: 14) {
                    Label(callDurationText, systemImage: "phone.fill")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    Button {
                        chatVM.setMicrophoneMuted(!chatVM.isMicrophoneMuted)
                    } label: {
                        Image(systemName: chatVM.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill")
                            .frame(width: 34, height: 34)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.thinMaterial)
                .clipShape(Capsule())
                .padding(.top, 10)
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if let started = callStartedAt {
                callElapsedSeconds = Int(Date().timeIntervalSince(started))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            longComposerControl

            composerCircleButton(
                icon: mode == .text ? "mic.fill" : "keyboard",
                action: {
                    if mode == .text {
                        enterPushToTalkMode()
                    } else {
                        returnToTextMode()
                    }
                }
            )

            composerCircleButton(
                icon: mode == .voiceCall ? "mic.fill" : "phone.fill",
                action: {
                    if mode == .voiceCall {
                        switchCallToPushToTalk()
                    } else {
                        beginVoiceCall()
                    }
                }
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
                Menu {
                    Button { chatVM.showCamera = true } label: {
                        Label("拍照", systemImage: "camera")
                    }
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("从相册选择", systemImage: "photo.on.rectangle")
                    }
                } label: {
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
        callStartedAt = Date()
        callElapsedSeconds = 0
        chatVM.startRealtimeConversation()
    }

    private func endVoiceCall() {
        chatVM.stopRealtimeConversation()
        callStartedAt = nil
        callElapsedSeconds = 0
        mode = .pushToTalk
    }

    private func switchCallToPushToTalk() {
        chatVM.stopRealtimeConversation()
        callStartedAt = nil
        callElapsedSeconds = 0
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

    private var callDurationText: String {
        String(format: "%02d:%02d", callElapsedSeconds / 60, callElapsedSeconds % 60)
    }

}

private struct ConversationMessageRow: View {
    let message: ChatMessage
    let onRecognizeText: (UIImage) -> Void

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
                        .contextMenu {
                            Button { onRecognizeText(image) } label: {
                                Label("识别并复制文字", systemImage: "text.viewfinder")
                            }
                        }
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
                        .contextMenu {
                            Button { UIPasteboard.general.string = message.text } label: {
                                Label("复制", systemImage: "doc.on.doc")
                            }
                            ShareLink(item: message.text) {
                                Label("分享", systemImage: "square.and.arrow.up")
                            }
                        }
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

            ScrollView(showsIndicators: false) {
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
            }
        }
        .padding(22)
    }
}

private struct ServiceSettingsSheet: View {
    @AppStorage(AppConfig.zhipuModelKey) private var zhipuModel = "glm-4v-flash"
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = AppConfig.zhipuAPIKey
    @State private var showKey = false

    private var canSave: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !zhipuModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("服务设置")
                        .font(.title2.bold())
                    Text("图片识别由智谱视觉大模型直接完成，不再需要电脑运行视觉服务。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("智谱 API Key")
                        .font(.headline)
                    HStack {
                        Group {
                            if showKey {
                                TextField("填写 BigModel API Key", text: $apiKey)
                            } else {
                                SecureField("填写 BigModel API Key", text: $apiKey)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                        Button { showKey.toggle() } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                        }
                    }
                    .padding(12)
                    .background(Color(uiColor: .systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    Text("API Key 仅保存在本机 Keychain，不会提交到 GitHub。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("视觉模型")
                        .font(.headline)
                    TextField("glm-4v-flash", text: $zhipuModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(Color(uiColor: .systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Text("默认使用 glm-4v-flash；是否免费以智谱控制台当前规则为准。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    zhipuModel = zhipuModel.trimmingCharacters(in: .whitespacesAndNewlines)
                    _ = KeychainHelper.save(key: AppConfig.zhipuAPIKeyKey, string: trimmedKey)
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
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.45)
            }
            .padding(22)
        }
    }
}

#Preview {
    ConversationView()
        .environmentObject(ChatViewModel())
}
