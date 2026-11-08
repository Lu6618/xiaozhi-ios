import SwiftUI
import PhotosUI
import Combine
import UIKit

private enum ConversationUIMode {
    case text
    case pushToTalk
    case voiceCall
}

struct ConversationView: View {
    @EnvironmentObject private var chatVM: ChatViewModel
    @StateObject private var audioMonitor = AudioVolumeMonitor()
    @StateObject private var live2DController = Live2DController()
    @StateObject private var settings = Live2DSettings.shared
    // Plain class (not ObservableObject — it publishes nothing), so @State, not @StateObject.
    @State private var composerStore = ComposerTextFieldStore()

    @State private var messageText = ""
    @State private var mode: ConversationUIMode = .pushToTalk
    @State private var isPressingToTalk = false
    @State private var showModelSelector = false
    @State private var showServiceSettings = false
    @State private var showHeaderActions = false
    @State private var showMediaActions = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showPhotoPicker = false
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
        .confirmationDialog("更多", isPresented: $showHeaderActions, titleVisibility: .hidden) {
            Button("服务设置") { showServiceSettings = true }
            Button("清空聊天记录", role: .destructive) {
                // 等当前弹窗收起后再弹清空确认，避免两个弹窗叠在一起
                DispatchQueue.main.async { showClearHistoryConfirmation = true }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("添加", isPresented: $showMediaActions, titleVisibility: .hidden) {
            Button("拍照") { openCamera() }
            Button("相册") { showPhotoPicker = true }
            Button("取消", role: .cancel) {}
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
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
        // Deep Link 一键通话：xiaozhi://call（View 消费标志后自己置回 false，再进通话）
        .onChange(of: chatVM.voiceCallRequested) { requested in
            guard requested else { return }
            chatVM.voiceCallRequested = false
            beginVoiceCall()
        }
        .onOpenURL { url in
            chatVM.handleDeepLink(url: url)
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

            Button { showHeaderActions = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
                    .background(Color(uiColor: .systemGray6))
                    .clipShape(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

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
            modelScale: settings.currentModel.scale,
            controller: live2DController,
            audioMonitor: audioMonitor
        )
        .id(settings.currentModel.dir)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .live2DInteraction(controller: live2DController) { isComposerFocused = false }
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
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var longComposerControl: some View {
        if mode == .text {
            HStack(spacing: 8) {
                Button { showMediaActions = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .medium))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // 真实的 UITextField（UIViewRepresentable）：发送时直接读它的 .text，
                // 不再读 SwiftUI 绑定快照。旧的 SwiftUI TextField 用 axis: .vertical，
                // 底层是 UITextView，build 90 的 `as? UITextField` 查找永远失败、
                // 永远回退到滞后的绑定——这就是打完字立刻发丢尾巴的原因。
                // 注意：$isComposerFocused 是 FocusState.Binding，不是 Binding<Bool>，
                // 须经 composerFocusBinding 桥接才能传给 UIViewRepresentable。
                ComposerTextField(text: $messageText, isFocused: composerFocusBinding, store: composerStore, onSubmit: sendMessage)
                    // 定死高度：光有 sizeThatFits 还不够，再加一层 frame 兜底。
                    // build 96 漏了高度约束，UITextField 被 SwiftUI 纵向拉满整屏，
                    // 输入框变成全屏大圆角白框、盖住聊天记录（Lu 16:26 截图）。
                    .frame(height: 36)

                // 发送按钮固定嵌在输入框内部右侧：有文字时蓝色可点，没文字时灰色不可点
                Button(action: sendMessage) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(isComposerEmpty ? Color.gray.opacity(0.6) : Color.blue)
                        .clipShape(Circle())
                }
                .disabled(isComposerEmpty)
                .buttonStyle(.plain)
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
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
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
        if chatVM.isReconnecting { return "正在重连…" }
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
        // 直接读底层 UITextField 的真实文本（先提交未确认的拼音组词），再读 .text：
        // 这是唯一可信的文本来源，包含输入框里显示的全部字符。
        // 不要读 SwiftUI 的 messageText 绑定——中文输入时拼音组词（marked text）
        // 不会同步到绑定，打完字马上点发送读绑定会丢最后几个字。
        let raw = composerStore.committedText() ?? messageText
        let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        chatVM.sendTextMessage(content)
        composerStore.clear()
        messageText = ""
    }

    private func openCamera() {
        chatVM.cancelCamera()
        chatVM.showCamera = true
    }

    /// @FocusState 桥接成普通 Binding<Bool>（FocusState.Binding 不是 Binding<Bool>，
    /// 不能直接传给 UIViewRepresentable）。
    private var composerFocusBinding: Binding<Bool> {
        Binding(
            get: { isComposerFocused },
            set: { isComposerFocused = $0 }
        )
    }

    private var isComposerEmpty: Bool {
        // 发送按钮的可用状态也要看输入框真实文本：拼音组词期间绑定可能滞后，
        // 只看绑定会让按钮在还有字时错误地变灰。
        let fieldText = composerStore.visibleText
        let current = fieldText.isEmpty ? messageText : fieldText
        return current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            // 未连接：先标记“连上后自动进通话”，再去连接；hello 到达后自动拉起，不用用户再点一次
            chatVM.notePendingVoiceCall()
            Task { await chatVM.connect() }
            return
        }
        mode = .voiceCall
        callStartedAt = Date()
        callElapsedSeconds = 0
        chatVM.startRealtimeConversation()
    }

    private func endVoiceCall() {
        chatVM.cancelPendingVoiceCall()
        chatVM.stopRealtimeConversation()
        callStartedAt = nil
        callElapsedSeconds = 0
        mode = .pushToTalk
    }

    private func switchCallToPushToTalk() {
        chatVM.cancelPendingVoiceCall()
        chatVM.stopRealtimeConversation()
        callStartedAt = nil
        callElapsedSeconds = 0
        mode = .pushToTalk
    }

    private func leaveVoiceMode() {
        chatVM.cancelPendingVoiceCall()
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
    @AppStorage(AppConfig.visionAPIBaseURLKey) private var baseURL = ""
    @AppStorage(AppConfig.visionAPITypeKey) private var apiTypeRaw = VisionAPIType.chat.rawValue
    @AppStorage(AppConfig.visionModelKey) private var visionModel = "glm-4v-flash"
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = AppConfig.visionAPIKey
    @State private var showKey = false
    @State private var fetchedModels: [String] = []
    @State private var isFetchingModels = false
    @State private var modelFetchError: String? = nil
    @State private var isTesting = false
    @State private var testResult: String? = nil
    @State private var testSucceeded: Bool? = nil

    private var apiType: VisionAPIType {
        VisionAPIType(rawValue: apiTypeRaw) ?? .chat
    }

    private var apiTypeBinding: Binding<VisionAPIType> {
        Binding(
            get: { apiType },
            set: { apiTypeRaw = $0.rawValue }
        )
    }

    private var trimmedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedModel: String {
        visionModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedKey.isEmpty &&
        !trimmedBaseURL.isEmpty &&
        !trimmedModel.isEmpty
    }

    private var canFetchModels: Bool {
        !trimmedBaseURL.isEmpty && !trimmedKey.isEmpty && !isFetchingModels
    }

    private var canTest: Bool {
        canSave && !isTesting
    }

    /// 首次打开时，把旧版存的完整接口地址迁移成基础地址 + 类型
    private func migrateLegacyEndpointIfNeeded() {
        guard trimmedBaseURL.isEmpty else { return }
        let legacy = UserDefaults.standard.string(forKey: AppConfig.visionEndpointKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !legacy.isEmpty, legacy != AppConfig.zhipuEndpoint else { return }
        baseURL = AppConfig.normalizeVisionBaseURL(legacy)
        if legacy.hasSuffix("/responses") {
            apiTypeRaw = VisionAPIType.responses.rawValue
        } else if legacy.hasSuffix("/chat/completions") {
            apiTypeRaw = VisionAPIType.chat.rawValue
        }
    }

    private func fetchModels() async {
        isFetchingModels = true
        modelFetchError = nil
        do {
            let models = try await VisionService.fetchModels(baseURL: baseURL, apiKey: apiKey)
            fetchedModels = models
            if models.isEmpty {
                modelFetchError = "接口没有返回任何模型，请检查地址和 Key，或手动输入模型名。"
            } else if trimmedModel.isEmpty {
                visionModel = models[0]
            }
        } catch {
            fetchedModels = []
            modelFetchError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isFetchingModels = false
    }

    private func runTest() async {
        isTesting = true
        testResult = nil
        testSucceeded = nil
        do {
            let reply = try await VisionService.testConnectivity(
                baseURL: baseURL, apiKey: apiKey, model: visionModel, type: apiType
            )
            testSucceeded = true
            testResult = "连接成功，模型回复：\(reply)"
        } catch {
            testSucceeded = false
            testResult = "连接失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
        isTesting = false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("服务设置")
                        .font(.title2.bold())
                    Text("图片识别使用你配置的 OpenAI 兼容视觉接口。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("视觉模型 API Key")
                        .font(.headline)
                    HStack {
                        Group {
                            if showKey {
                                TextField("填写视觉模型 API Key", text: $apiKey)
                            } else {
                                SecureField("填写视觉模型 API Key", text: $apiKey)
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
                    Text("请求地址")
                        .font(.headline)
                    TextField("https://agentrouter.698668.xyz/v1", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .padding(12)
                        .background(Color(uiColor: .systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Text("只填基础地址，不用加 /chat/completions 或 /responses，App 会按 API 类型自动拼。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("API 类型")
                        .font(.headline)
                    Picker("API 类型", selection: apiTypeBinding) {
                        ForEach(VisionAPIType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("只支持 Responses 的模型（例如 AgentRouter 的 gpt-6.1-sol）请选 Responses。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("视觉模型")
                        .font(.headline)
                    Button {
                        Task { await fetchModels() }
                    } label: {
                        HStack(spacing: 6) {
                            if isFetchingModels {
                                ProgressView()
                            }
                            Text(isFetchingModels ? "正在获取…" : "获取模型列表")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(.white)
                        .background(canFetchModels ? Color.blue : Color.gray)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(!canFetchModels)
                    if let modelFetchError {
                        Text(modelFetchError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if !fetchedModels.isEmpty {
                        Picker("选择模型", selection: $visionModel) {
                            ForEach(fetchedModels, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .pickerStyle(.menu)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(uiColor: .systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    TextField("模型名称，例如 glm-4v-flash", text: $visionModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(Color(uiColor: .systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Text("拉不到列表时也可以手动输入模型名。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("连通性测试")
                        .font(.headline)
                    Button {
                        Task { await runTest() }
                    } label: {
                        HStack(spacing: 6) {
                            if isTesting {
                                ProgressView()
                            }
                            Text(isTesting ? "正在测试…" : "测试连通性")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .foregroundStyle(.white)
                        .background(canTest ? Color.green : Color.gray)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(!canTest)
                    if let testResult {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(testSucceeded == true ? .green : .red)
                    } else {
                        Text("用当前地址、Key、类型和模型发一次最短的纯文本请求，不发图。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    visionModel = trimmedModel
                    baseURL = trimmedBaseURL
                    _ = KeychainHelper.save(key: AppConfig.visionAPIKeyKey, string: trimmedKey)
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
        .onAppear {
            migrateLegacyEndpointIfNeeded()
        }
    }
}

#Preview {
    ConversationView()
        .environmentObject(ChatViewModel())
}
