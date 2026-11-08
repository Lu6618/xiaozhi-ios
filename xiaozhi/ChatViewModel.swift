//
//  ChatViewModel.swift
//  xiaozhi
//
//  Created by Lee on 2025/12/2.
//  Refactored Version
//

import Foundation
import Combine
import UIKit
import AVFoundation
import CoreLocation
import Vision

enum AppState: Equatable {
    case idle
    case listening
    case speaking
    case connecting
    case awaitingActivation
    case connectionFailed
}

enum ActiveSheet: Identifiable {
    case xhsResult
    case xhsPublish
    case mapResult
    case htmlResult
    
    var id: Int { hashValue }
}

class ChatViewModel: ObservableObject {
    
    // ----------------------------------------------------------------
    // MARK: - Published Properties (UI State)
    // ----------------------------------------------------------------
    
    @Published var messageList: [ChatMessage] = [] {
        didSet { scheduleHistorySave() }
    }
    @Published var appState: AppState = .connecting
    @Published var showActivationAlert = false
    @Published var activationMessage = ""
    @Published var isHandsFreeMode: Bool = false
    @Published var isMicrophoneMuted: Bool = false
    /// 回前台正在重连（UI 显示“正在重连…”）；会话建立（hello 到达）或用户主动断开时清掉。
    @Published var isReconnecting = false
    
    // Sheets & Popups
    @Published var activeSheet: ActiveSheet?
    @Published var showCamera = false
    
    // XHS Data
    @Published var xhsFeeds: [XhsFeed] = []
    @Published var selectedNoteDetail: XhsNoteDetail?
    @Published var showPublishSheet = false
    @Published var showNoteDetail = false
    
    // Publish Data
    @Published var publishDraftImage: UIImage?
    @Published var publishDraftTitle = ""
    @Published var publishDraftContent = ""
    private var publishDraftBase64: String = ""
    
    // Map Data
    @Published var mapPOIs: [AmapPOI] = []
    @Published var mapRoute: AmapRoute?
    
    // HTML Data
    @Published var generatedHtml: String?
    private var pendingHtmlBuffer: String?
    
    enum VisionTaskType {
        case analyze
        case publishXhs
    }
    
    // ----------------------------------------------------------------
    // MARK: - Internal Dependencies
    // ----------------------------------------------------------------
    
    private let webSocketManager = WebSocketManager.shared
    private let audioService = AudioService.shared
    private let mcpManager = MCPManager() // ✅ MCP 管理器
    private let localSynthesizer = AVSpeechSynthesizer()
    
    private var currentSessionId: String?
    
    // 断线缓存语音:未连接时按下说话,先本地录音攒包,连上后补发
    private var isBufferingVoice = false
    private var pendingVoicePackets: [Data] = []
    private var pendingVoiceFlush = false
    private var pendingVoiceDate: Date?
    private let historyURL: URL = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("xiaozhi-chat-history.json")
    }()
    private var historySaveTask: Task<Void, Never>?
    private var activationPollingTask: Task<Void, Never>?
    /// 用户主动断开后不再自动重连（回前台也不重连，直到用户再次操作）
    private var userDisconnected = false
    
    // MCP Pending States (等待拍照)
    private var pendingMcpRequestId: Int?
    private var pendingMcpSessionId: String?
    private var currentVisionTask: VisionTaskType = .analyze
    /// 上次成功交付视觉结果的时间。mcpDidRequestCamera 用它屏蔽随后误触发的 take_photo。
    private var lastVisionDeliveredAt: Date?
    
    // 本地语音锁 (防止 AI 插嘴)
    private var isLocalSpeaking = false
    
    @Published var isSearching = false
    
    @Published var isDouyinAutoMode = false
    
    // 记录上一次欢迎的时间，用于限流
    private var lastWelcomeTime: Date = .distantPast
    
    // 在类定义的属性区域添加：
    private var lastDouyinProcessTime: Date = .distantPast
    private var isInjectingVoice = false          // 标记是否正在静默注入
    private var isShowBubble = false //默认上屏
    
    // 2. 标记系统是否正在本地播报
    private var isSystemSpeaking = false
    
    // 公开的连接状态属性
    var isConnected: Bool {
        return webSocketManager.isConnected && currentSessionId != nil
    }
    
    private var configService = AppConfigService.shared
    
    // ----------------------------------------------------------------
    // MARK: - Init
    // ----------------------------------------------------------------
    
    init() {
        loadHistory()
        // 设置代理
        mcpManager.delegate = self
        webSocketManager.delegate = self
        DouyinManager.shared.delegate = self
        
        if self.isSystemSpeaking {
            return
        }
        
        // 音频回调: 只有在 listening 状态下才发送音频
        audioService.onOpusPacket = { [weak self] opusData in
            guard let self = self else { return }
            // print(">>> Audio Packet: \(opusData.count) bytes")
            if self.isBufferingVoice {
                // 断线缓存:录音包先存本地,连上后补发 (主队列追加,保证顺序且无竞态)
                DispatchQueue.main.async {
                    if self.isBufferingVoice && self.pendingVoicePackets.count < 1500 {
                        self.pendingVoicePackets.append(opusData)
                    }
                }
                return
            }
            if (self.appState == .listening && !self.isMicrophoneMuted) || self.isInjectingVoice {
                self.webSocketManager.sendAudio(data: opusData)
            }
        }
        
        // 回前台自动重连：App 切后台被系统挂起杀掉 socket 后，回到前台立即重连
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @objc private func handleWillEnterForeground() {
        Task { @MainActor in self.handleForegroundReturn() }
    }

    /// 回前台：立刻自动重连，不等、不靠定时器轮询。
    /// build 83 的问题：只在 isConnected == false 时才重连，但后台被系统挂起杀掉 socket 后，
    /// close 事件根本没送达，isConnected 仍残留 true，于是直接 return、一次重连都不跑，
    /// 用户看到的就是“直接断了”。现在有会话就强制重连（reconnectNow 会先取消旧任务），
    /// UI 显示“正在重连…”。聊天记录在本地，不丢上下文。
    /// 用户主动断开（disconnect()）后不自动重连；等待激活状态下也不重连。
    @MainActor
    func handleForegroundReturn() {
        guard !userDisconnected, appState != .awaitingActivation else { return }
        isReconnecting = true
        appState = .connecting
        if currentSessionId != nil {
            webSocketManager.reconnectNow()
        } else {
            Task { await connect() }
        }
    }
    
    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let messages = try? JSONDecoder().decode([ChatMessage].self, from: data) else { return }
        messageList = messages
    }

    private func scheduleHistorySave() {
        historySaveTask?.cancel()
        let snapshot = Array(messageList.suffix(100))
        let url = historyURL
        historySaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                print("History save failed: \(error)")
            }
        }
    }

    @MainActor
    func clearConversationHistory() {
        historySaveTask?.cancel()
        messageList.removeAll()
        try? FileManager.default.removeItem(at: historyURL)
    }

    @MainActor
    func processSelectedImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.72) else { return }
        processCapturedImage(base64Str: data.base64EncodedString())
    }

    func recognizeText(in image: UIImage) async -> String {
        guard let cgImage = image.cgImage else { return "" }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil else { continuation.resume(returning: ""); return }
                let text = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n") ?? ""
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            DispatchQueue.global(qos: .userInitiated).async {
                try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            }
        }
    }

    func setMode(handsFree: Bool) {
        self.isHandsFreeMode = handsFree
        print(">>> 切换模式: \(handsFree ? "免提 (Auto)" : "按键 (Manual)")")
    }
    
    // ----------------------------------------------------------------
    // MARK: - Connection Logic
    // ----------------------------------------------------------------
    
    @MainActor
    func connect() async {
        userDisconnected = false
        if activationPollingTask != nil && appState == .awaitingActivation {
             return
        }
        
        // 强制重连
        if webSocketManager.isConnected {
            webSocketManager.disconnect()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        
        webSocketManager.delegate = self
        self.appState = .connecting
        
        let macAddress = IdentityManager.pseudoMacAddress
        let uuid = IdentityManager.clientId
        
        // OTA 请求
        let otaRequest = OtaRequest(
            version: 2, language: "zh-CN", flashSize: 16777216,
            minimumFreeHeapSize: 8457848, macAddress: macAddress,
            chipModelName: "Apple-Silicon", uuid: uuid,
            application: ApplicationInfo(name: "xiaozhi-ios", version: "1.0.0", compileTime: "Now", idfVersion: "N/A", elfSha256: "fake"),
            partitionTable: [], ota: OtaInfo(partition: "ota_0"),
            board: BoardInfo(type: "xingzhi-ios", name: "\(UIDevice.current.model)", ssid: "Wifi", rssi: -50, channel: 0, ip: "127.0.0.1", mac: macAddress)
        )
        
        do {
            let otaResponse = try await APIService.shared.checkOta(requestBody: otaRequest)
            
            print("***************\(configService.isFullFeatureEnabled)")
            
            if let activationInfo = otaResponse.activation, !activationInfo.code.isEmpty {
                self.appState = .awaitingActivation
                self.activationMessage = activationInfo.message
                self.showActivationAlert = true
                startPollingForActivation()
            } else {
                stopPollingForActivation()
                self.showActivationAlert = false
                
                print("--------------deviceId--------")
                print("\(IdentityManager.pseudoMacAddress)")
                print("--------------clientId--------")
                print("\(IdentityManager.clientId)")
                
                
                if let url = URL(string: otaResponse.websocket.url) {
                    webSocketManager.connect(url: url, token: otaResponse.websocket.token, deviceId: macAddress, clientId: uuid)
                    // 手动模式保持麦克风关闭，按住说话或进入通话时再启动。
                
                } else {
                    self.appState = .connectionFailed
                }
            }
        } catch {
            print("OTA Error: \(error)")
            if activationPollingTask == nil {
                self.appState = .connectionFailed
            }
        }
    }
    
    @MainActor
    func disconnect() {
        // 1. 调用 WebSocketManager 的断开 (这里 webSocketManager 是 ViewModel 的属性)
        webSocketManager.disconnect(reason: "User Exit")
        userDisconnected = true
        isReconnecting = false
        cancelPendingVoiceCall()
        
        // 2. 只有 ViewModel 才有权限控制 audioService 和 appState
        audioService.stopRecording()
        audioService.stopPlaying()
        currentSessionId = nil
        appState = .idle
        // 断线缓存语音一并丢弃
        isBufferingVoice = false
        pendingVoiceFlush = false
        pendingVoicePackets.removeAll()
        pendingVoiceDate = nil
        stopPollingForActivation()
    }

    // ----------------------------------------------------------------
    // MARK: - Deep Link（一键通话）
    // ----------------------------------------------------------------

    /// View 监听到它变 true 就切到通话界面并进通话；View 消费后自己置回 false。
    @Published var voiceCallRequested = false
    /// 未连接时的一键通话请求：连上（hello 到达）后自动进通话，不用用户再点。
    private var pendingVoiceCall = false
    /// deep link 带的 text 参数：通话开始后直接发出去，用完即清。
    private var pendingDeepLinkText: String?

    /// 一键通话入口（deep link 用）：标记待进通话，并通知 View 切界面。
    @MainActor
    func requestVoiceCall() {
        pendingVoiceCall = true
        voiceCallRequested = true
    }

    /// 通话按钮在未连接时调用：只标记待进通话，不通知 View（View 已经在处理了）。
    @MainActor
    func notePendingVoiceCall() {
        pendingVoiceCall = true
    }

    /// 用户离开通话界面 / 主动断开时取消待进通话，避免之后 hello 到达又自动拉起通话。
    @MainActor
    func cancelPendingVoiceCall() {
        pendingVoiceCall = false
        pendingDeepLinkText = nil
    }

    /// 处理外部 URL：
    /// - xiaozhi://call —— 打开 App 后直接开始语音通话（免提，自动连接、自动进通话）
    /// - xiaozhi://call?text=你好 —— 同上，通话开始后把这句话直接发给小智
    /// - xiaozhi://chat —— 打开到聊天页（默认行为，什么都不做）
    @MainActor
    func handleDeepLink(url: URL) {
        guard url.scheme?.lowercased() == "xiaozhi" else { return }
        switch url.host?.lowercased() ?? "" {
        case "call":
            let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "text" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let text, !text.isEmpty { pendingDeepLinkText = text }
            requestVoiceCall()
        case "chat":
            break
        default:
            break
        }
    }

    @MainActor
    private func startPollingForActivation() {
        guard activationPollingTask == nil else { return }
        activationPollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                await connect()
            }
        }
    }
    
    private func stopPollingForActivation() {
        activationPollingTask?.cancel()
        activationPollingTask = nil
    }
    
    // ----------------------------------------------------------------
    // MARK: - Speech & User Interaction
    // ----------------------------------------------------------------
    
    @MainActor
    func speakLocally(text: String) {
        // UI 上屏
        let sysMessage = ChatMessage(text: text, type: .received)
        self.messageList.append(sysMessage)
        
        print(">>> 🔊 本地播报: \(text)")
        
        // 停止录音播放，独占音频
        self.isSystemSpeaking = true
        self.isLocalSpeaking = true
        audioService.stopRecording()
        audioService.stopPlaying()
        
        // 播放 TTS
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.5
        
        // 监听播放结束 (简单处理，设定一个延时恢复标记)
        localSynthesizer.speak(utterance)
        
        // 粗略估算语音时长：每秒 4 个字
        let duration = Double(text.count) / 4.0 + 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            self.isLocalSpeaking = false
            // 如果是免提模式，恢复监听
            if self.isHandsFreeMode && self.appState != .speaking {
                self.startAutoListening()
            }
        }
    }
    
    // ✅ 【新增】从 Live2D 无缝切换回手动模式
    @MainActor
    func prepareForManualMode() {
        print(">>> 🔄 准备切换回手动模式")
        
        // 1. 重新绑定 WebSocket 代理 (防止在其他地方丢失)
        webSocketManager.delegate = self
        
        // 2. 重置音频回调 (确保回调闭包里的 self 是正确的)
        audioService.onOpusPacket = { [weak self] opusData in
            guard let self = self else { return }
            if self.isSystemSpeaking { return }
            
            if self.isBufferingVoice {
                // 断线缓存:录音包先存本地,连上后补发 (主队列追加,保证顺序且无竞态)
                DispatchQueue.main.async {
                    if self.isBufferingVoice && self.pendingVoicePackets.count < 1500 {
                        self.pendingVoicePackets.append(opusData)
                    }
                }
                return
            }
            
            // 仅在监听状态发送数据
            if (self.appState == .listening && !self.isMicrophoneMuted) || self.isInjectingVoice {
                self.webSocketManager.sendAudio(data: opusData)
            }
        }
        
        // 3. 停止播放
        audioService.stopPlaying()
        
        // 4. 手动模式不预热麦克风，避免空闲时持续占用系统录音。
        audioService.stopRecording()
        
        // 5. 重置状态
        isHandsFreeMode = false
        appState = .idle
    }
    
    @MainActor
    func startUserSpeech() {
        // 已连接:原逻辑 (先清掉旧的断线缓存,避免旧包混入实时流)
        if let sid = currentSessionId, webSocketManager.isConnected {
            isBufferingVoice = false
            pendingVoiceFlush = false
            pendingVoicePackets.removeAll()
            pendingVoiceDate = nil
            
            // UI 增加 "..."
            messageList.append(ChatMessage(text: "...", type: .sent))
            
            appState = .listening
            if !audioService.isRecording {
                audioService.startRecording()
            }
            
            sendJson(["session_id": sid, "type": "listen", "state": "start", "mode": "manual"])
            return
        }
        
        // 未连接:不等重连,先本地录音攒包,后台重连;连上后补发,回复随后到
        print("⚠️ [Speech] 未连接,先本地录音攒包,连上后补发...")
        messageList.append(ChatMessage(text: "...", type: .sent))
        pendingVoicePackets.removeAll()
        pendingVoiceFlush = false
        pendingVoiceDate = nil
        isBufferingVoice = true
        appState = .connecting
        if !audioService.isRecording {
            audioService.startRecording()
        }
        Task { await connect() }
    }
    
    
    @MainActor
    func stopUserSpeech() {
        // 正在断线攒包:停录,标记待补发 (isBufferingVoice 先不清,让在途的包安全落袋,补发时再清)
        if isBufferingVoice {
            print(">>> 🛑 [Speech] 断线攒包结束,待连上后补发...")
            audioService.stopRecording()
            pendingVoiceFlush = true
            pendingVoiceDate = Date()
            return
        }
        
        guard appState == .listening, let sid = currentSessionId else { return }
        
        print(">>> 🛑 [Speech] Stopping recording...")
        
        appState = .idle
        audioService.stopRecording()
        
        sendJson(["session_id": sid, "type": "listen", "state": "stop"])
    }

    @MainActor
    func sendTextMessage(_ text: String) {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        // 本地打车意图：说“打车去XX/叫车去XX”直接打开高德打车页，不发给服务器
        // （打车比导航更具体，先判打车；“我要打车去XX”不含导航触发词，不会被导航抢走）
        if let dest = Self.extractTaxiDestination(from: content) {
            messageList.append(ChatMessage(text: content, type: .sent))
            navigateToTaxi(destination: dest)
            return
        }

        // 本地导航意图：说“去XX/导航到XX”直接打开高德导航，不发给服务器
        if let dest = Self.extractNavigationDestination(from: content) {
            messageList.append(ChatMessage(text: content, type: .sent))
            navigateTo(destination: dest)
            return
        }

        guard currentSessionId != nil, webSocketManager.isConnected else {
            appState = .connecting
            Task { await connect() }
            return
        }

        messageList.append(ChatMessage(text: content, type: .sent))

        // 对话里生图：先过一个快速本地门控（只有可能与生图有关才问模型，避免每次对话都多一次调用），
        // 再让配置的大模型判断是不是生图请求并提炼描述；是则走生图，否则走原来的小智语音对话。
        guard ImageGenerationService.mightBeImageRequest(content) else {
            injectVoiceCommand(text: content, showBubble: true)
            return
        }
        Task {
            if let prompt = await ImageGenerationService.shared.detectImagePrompt(for: content) {
                await self.generateImageFromChat(prompt: prompt)
            } else {
                await MainActor.run { self.injectVoiceCommand(text: content, showBubble: true) }
            }
        }
    }

    /// 对话里触发的生图：用服务设置里的同一套配置生成图片，显示在对话里
    @MainActor
    private func generateImageFromChat(prompt: String) async {
        let loading = ChatMessage(text: "🎨 正在生成图片…", type: .received)
        messageList.append(loading)
        do {
            let data = try await ImageGenerationService.shared.generateWithVisionConfig(prompt: prompt)
            guard let image = UIImage(data: data) else { throw ImageGenerationError.invalidResponse }
            if let idx = messageList.firstIndex(where: { $0.id == loading.id }) {
                messageList[idx] = ChatMessage(text: "图片已生成", type: .received, image: image)
            } else {
                messageList.append(ChatMessage(text: "图片已生成", type: .received, image: image))
            }
        } catch {
            if let idx = messageList.firstIndex(where: { $0.id == loading.id }) {
                messageList.remove(at: idx)
            }
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            speakLocally(text: "生图失败：\(reason)")
        }
    }

    // ----------------------------------------------------------------
    // MARK: - 本地导航意图（打开系统高德地图）
    // ----------------------------------------------------------------

    /// 从一句话里提取导航目的地。只认明确的导航说法，返回 nil 表示不是导航请求。
    /// 旅游攻略类（攻略/行程/旅游/旅行）不归这里管，仍走原来的旅行规划。
    static func extractNavigationDestination(from text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        // 旅游攻略优先走旅行规划，不抢
        if value.contains("攻略") || value.contains("行程") || value.contains("旅游") || value.contains("旅行") {
            return nil
        }
        // 长触发词优先，避免“导航”被先吃掉导致“导航到”剩不下地名
        let triggers = ["帮我导航到", "导航到", "带我去", "我要去", "我想去", "开车去", "怎么去", "导航去", "导航"]
        var destination: String?
        for trigger in triggers {
            if let range = value.range(of: trigger) {
                let rest = String(value[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty {
                    destination = rest
                }
                break
            }
        }
        if destination == nil, value.hasPrefix("去"), value.count >= 3 {
            destination = String(value.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard var dest = destination, !dest.isEmpty else { return nil }
        // 去掉末尾的语气词/后缀
        for suffix in ["怎么走", "的路线", "路线", "导航", "一下"] {
            if dest.hasSuffix(suffix) {
                dest = String(dest.dropLast(suffix.count))
            }
        }
        dest = dest.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "，。！？、,.!? "))
        guard !dest.isEmpty, dest != "哪里", dest != "哪儿", dest != "那" else { return nil }
        return dest
    }

    /// 打开系统高德地图导航到指定目的地。
    /// 先试后端地理编码拿坐标（3 秒超时，失败就直接用名字导航，高德自己会解析地名，
    /// 所以不依赖后端也能用）；没装高德时明确语音+文字提示，不静默失败。
    @MainActor
    func navigateTo(destination: String) {
        let dest = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dest.isEmpty else { return }
        messageList.append(ChatMessage(text: "正在为你导航到\(dest)…", type: .received))
        Task {
            var poi: AmapPOI?
            do {
                poi = try await withThrowingTaskGroup(of: AmapPOI?.self) { group in
                    group.addTask {
                        try await MapService.searchPOI(keywords: dest, city: LocationManager.shared.currentCity).1.first
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 3_000_000_000)
                        return nil
                    }
                    let first = try await group.next() ?? nil
                    group.cancelAll()
                    return first
                }
            } catch {
                poi = nil
            }
            await MainActor.run {
                if let poi = poi {
                    if AmapNavigationService.openNavigation(poi: poi) {
                        self.speakLocally(text: "正在打开高德地图，导航到\(dest)。")
                    } else {
                        self.speakLocally(text: "没有安装高德地图，请先安装高德地图再导航。")
                    }
                } else {
                    if AmapNavigationService.openNavigationToName(dest) {
                        self.speakLocally(text: "正在打开高德地图，导航到\(dest)。")
                    } else {
                        self.speakLocally(text: "没有安装高德地图，请先安装高德地图再导航。")
                    }
                }
            }
        }
    }

    /// 从一句话里提取打车目的地。只认明确的打车说法，返回 nil 表示不是打车请求。
    /// “我要打车去XX”不含导航触发词，不会被导航抢走；旅游攻略类不归这里管。
    static func extractTaxiDestination(from text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.contains("攻略") || value.contains("行程") || value.contains("旅游") || value.contains("旅行") {
            return nil
        }
        // 长触发词优先，避免“打车”先吃掉导致“打车去”剩不下地名
        let triggers = ["打车去", "叫车去", "打车到", "叫车到", "打车", "叫车"]
        var destination: String?
        for trigger in triggers {
            if let range = value.range(of: trigger) {
                let rest = String(value[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty {
                    destination = rest
                }
                break
            }
        }
        guard var dest = destination, !dest.isEmpty else { return nil }
        if dest.hasSuffix("一下") {
            dest = String(dest.dropLast("一下".count))
        }
        dest = dest.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "，。！？、,.!? "))
        guard !dest.isEmpty else { return nil }
        return dest
    }

    /// 打开系统高德地图打车到指定目的地。
    /// 坐标获取顺序（本机优先，不依赖连不上的本地后端）：
    /// ① 本机 CLGeocoder 地理编码（WGS-84 -> GCJ-02 转换，快，通常 1 秒内）；
    /// ② 后端 POI 搜索（127.0.0.1:8005，真机上连不上，3 秒超时兜底）；
    /// ③ 只带名字的链接（高德 takeTaxi 不认纯 dname，大概率只打开通用打车页）。
    /// 没装高德时明确语音+文字提示，不静默失败。
    @MainActor
    func navigateToTaxi(destination: String) {
        let dest = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dest.isEmpty else { return }
        messageList.append(ChatMessage(text: "正在为你叫车去\(dest)…", type: .received))
        Task {
            // ① 本机地理编码拿坐标
            if let coord = await LocalGeocoder.geocode(dest) {
                await MainActor.run {
                    if AmapNavigationService.openTaxiToCoordinate(name: dest, latitude: coord.latitude, longitude: coord.longitude) {
                        self.speakLocally(text: "正在打开高德地图，叫车去\(dest)。")
                    } else {
                        self.speakLocally(text: "没有安装高德地图，请先安装高德地图再打车。")
                    }
                }
                return
            }
            // ② 后端 POI 搜索（3 秒超时）
            var poi: AmapPOI?
            do {
                poi = try await withThrowingTaskGroup(of: AmapPOI?.self) { group in
                    group.addTask {
                        try await MapService.searchPOI(keywords: dest, city: LocationManager.shared.currentCity).1.first
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 3_000_000_000)
                        return nil
                    }
                    let first = try await group.next() ?? nil
                    group.cancelAll()
                    return first
                }
            } catch {
                poi = nil
            }
            await MainActor.run {
                if let poi = poi {
                    if AmapNavigationService.openTaxi(poi: poi) {
                        self.speakLocally(text: "正在打开高德地图，叫车去\(dest)。")
                    } else {
                        self.speakLocally(text: "没有安装高德地图，请先安装高德地图再打车。")
                    }
                } else {
                    // ③ 只带名字回退（takeTaxi 可能不认纯 dname，只打开通用打车页）
                    if AmapNavigationService.openTaxiToName(dest) {
                        self.speakLocally(text: "正在打开高德地图，叫车去\(dest)。")
                    } else {
                        self.speakLocally(text: "没有安装高德地图，请先安装高德地图再打车。")
                    }
                }
            }
        }
    }

    /// 服务器回复里若含高德链接（amapuri:// / iosamap://，如地图工具回的打车/导航链接），
    /// 直接打开高德 App，不要只当文本显示。只认这两个 scheme；同一条链接只打开一次。
    private var lastOpenedAmapLink: String?

    private func openAmapLinkIfPresent(in text: String) {
        guard let urlString = Self.firstAmapURLString(in: text),
              urlString != lastOpenedAmapLink else { return }
        guard let url = URL(string: urlString) ?? URLComponents(string: urlString)?.url else { return }
        lastOpenedAmapLink = urlString
        UIApplication.shared.open(url)
    }

    private static func firstAmapURLString(in text: String) -> String? {
        let pattern = "(amapuri|iosamap)://[^\\s\"'<>]+"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }

    @MainActor
    func setMicrophoneMuted(_ muted: Bool) {
        isMicrophoneMuted = muted
    }

    @MainActor
    func startRealtimeConversation() {
        guard currentSessionId != nil, webSocketManager.isConnected else {
            appState = .connecting
            Task { await connect() }
            return
        }

        isMicrophoneMuted = false
        setMode(handsFree: true)
        startAutoListening()
        // deep link 带的一句话（xiaozhi://call?text=...）：通话开始后直接发给小智
        if let text = pendingDeepLinkText, !text.isEmpty {
            pendingDeepLinkText = nil
            injectVoiceCommand(text: text, showBubble: true)
        }
    }

    @MainActor
    func stopRealtimeConversation() {
        if appState == .listening {
            stopUserSpeech()
        }
        isHandsFreeMode = false
        isMicrophoneMuted = false
        audioService.stopPlaying()
        audioService.stopRecording()
        appState = .idle
    }

    @MainActor
    func interruptAssistantForVoiceCall() {
        guard isHandsFreeMode, appState == .speaking, let sid = currentSessionId else { return }

        audioService.stopPlaying()
        sendJson(["session_id": sid, "type": "abort"])
        appState = .idle
        startAutoListening()
    }
    
    
    // 自动模式逻辑
    @MainActor
    func startAutoListening() {
        guard let sid = currentSessionId, isHandsFreeMode else { return }
        appState = .listening
        audioService.startRecording()
        sendJson(["session_id": sid, "type": "listen", "state": "start", "mode": "auto"])
    }
    
    @MainActor
    func pauseAutoListeningForAI() {
        guard isHandsFreeMode else { return }
        // 播放回复期间关闭录音，避免扬声器回声触发服务端 VAD。
        audioService.stopRecording()
    }
    
    // ----------------------------------------------------------------
    // MARK: - Camera & Publish Logic
    // ----------------------------------------------------------------
    
    @MainActor
    func processCapturedImage(base64Str: String) {
        self.showCamera = false
        
        // 1. 回显图片
        if let data = Data(base64Encoded: base64Str),
           let originalImage = UIImage(data: data) {
            let photoMsg = ChatMessage(text: "", type: .sent, image: originalImage)
            self.messageList.append(photoMsg)
        }
        
        // 2. 抓 MCP 待回执（分析完再回；先清状态，避免重入）
        let mcpReqId = pendingMcpRequestId
        let mcpSid = pendingMcpSessionId
        resetMcpState()
        
        // 3. 异步分析
        let loadingMsg = ChatMessage(text: "✨ 正在识别图片内容...", type: .received)
        self.messageList.append(loadingMsg)
        
        Task {
            do {
                let result = try await VisionService.analyze(base64: base64Str)
                print(">>> 👁️ 视觉分析结果: \(result)")
                
                if let last = self.messageList.last, last.text.contains("正在识别") {
                    self.messageList.removeLast()
                }
                
                // 标记：刚交付过视觉结果（mcpDidRequestCamera 里的守卫用，
                // 屏蔽服务器随后误触发的 take_photo）
                self.lastVisionDeliveredAt = Date()
                
                if let reqId = mcpReqId, let sid = mcpSid {
                    // A. MCP 触发的拍照：识别结果直接作为工具回执发回服务器。
                    // 工具回执是“已完成的观察”，大模型只会据此回复，不会再调 take_photo。
                    // 绝不能走 injectVoiceCommand：语音注入会伪装成用户又说了一句关于照片的话，
                    // 大模型一听“照片/图”就再次调 take_photo，相机反复弹出（build 109 的教训）。
                    // 提示词模板仍用于拼这条回执（工具回执里出现“照片”二字无妨，因为它不是用户发言）。
                    let reply = AppConfig.renderVisionPrompt(description: result)
                    mcpManager.sendSuccess(id: reqId, sessionId: sid, text: reply)
                } else {
                    // B. 用户主动拍照/选图：走语音注入（injectVoiceCommand）发给小智。
                    // 注意：冷发的 {"type": "text"} 文本消息在服务端没有对应的处理器，
                    // 会被静默丢弃、小智永远不回（build 112 的教训：图片识别不返回任何内容）。
                    // 语音注入是 App 里唯一能让服务器回话的路径（打字消息也走这条路）。
                    // 内容只发净化后的画面描述（去掉“照片/图片/图/拍”等触发词），
                    // 末尾加“你觉得怎么样？”让小智直接给看法、不去调工具；
                    // showBubble=false，用户只看到照片和小智的回复。
                    var clean = Self.sanitizeVisionDescription(result)
                    if clean.isEmpty { clean = result }
                    self.injectVoiceCommand(text: "\(clean)。你觉得怎么样？", showBubble: false)
                }
                
            } catch {
                print("Vision Error: \(error)")
                if let last = self.messageList.last, last.text.contains("正在识别") {
                    self.messageList.removeLast()
                }
                if let reqId = mcpReqId, let sid = mcpSid {
                    // MCP 任务失败也要回执，否则服务器会一直等工具结果
                    mcpManager.sendError(id: reqId, sessionId: sid, message: "图片识别失败")
                } else {
                    let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.speakLocally(text: "图片识别失败：\(reason)")
                }
            }
        }
    }
    
    // MARK: - 视觉结果交付（防相机误触发）
    
    /// 净化视觉识别结果：去掉“照片/图片/图/拍”等会触发小智调相机的词。
    /// “图”只去固定搭配（图中/图里/这张图），不单字去，以免误伤“地图/图案”等词；
    /// “看”也不动（“看起来”是形容词，大模型能分清它和“看一下”的区别）。
    static func sanitizeVisionDescription(_ text: String) -> String {
        var out = text
        // 长短语在前，避免短的先切坏长的
        let phrases = [
            "这张照片", "这张图片", "这幅照片", "这幅图片", "这图", "此图",
            "照片里", "照片中", "照片上", "照片显示", "照片",
            "图片里", "图片中", "图片上", "图片显示", "图片",
            "画面里", "画面中", "画面上", "画面显示", "画面",
            "图中", "图里", "图上", "这张图",
            "拍照", "拍摄", "拍一张",
            "镜头里", "镜头中"
        ]
        for p in phrases {
            out = out.replacingOccurrences(of: p, with: "")
        }
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = out.first, "，。、：；".contains(first) {
            out.removeFirst()
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

//    func processCapturedImage(base64Str: String) {
//        self.showCamera = false
//        
//        guard let reqId = pendingMcpRequestId, let sid = pendingMcpSessionId else { return }
//        // 1. 解码图片
//        guard let data = Data(base64Encoded: base64Str),
//              let originalImage = UIImage(data: data) else { return }
//        
//        let photoMsg = ChatMessage(text: "", type: .sent, image: originalImage)
//                self.messageList.append(photoMsg)
//        
//        print(">>> 🖼️ 照片已获取，任务类型: \(currentVisionTask)")
//        
//        if currentVisionTask == .analyze {
//            // 视觉分析任务
//            Task {
//                do {
//                    let result = try await VisionService.analyze(base64: base64Str)
//                    mcpManager.sendSuccess(id: reqId, sessionId: sid, text: result)
//                } catch {
//                    mcpManager.sendError(id: reqId, sessionId: sid, message: "Analysis failed")
//                }
//                resetMcpState()
//            }
//        } else if currentVisionTask == .publishXhs {
//            // 发布小红书任务 -> 进入编辑页
//            if let data = Data(base64Encoded: base64Str), let img = UIImage(data: data) {
//                self.publishDraftImage = img
//            }
//            self.publishDraftBase64 = base64Str // 暂存 Base64
//            self.showPublishSheet = true
//        }
//    }
    
    @MainActor
    func cancelCamera() {
        self.showCamera = false
        if let reqId = pendingMcpRequestId, let sid = pendingMcpSessionId {
            mcpManager.sendError(id: reqId, sessionId: sid, code: -3, message: "User cancelled")
        }
        resetMcpState()
    }
    
    @MainActor
    func confirmPublish(finalImage: UIImage) {
        guard let reqId = pendingMcpRequestId, let sid = pendingMcpSessionId else {
            self.showPublishSheet = false
            return
        }
        
        guard let imageData = finalImage.jpegData(compressionQuality: 0.6) else { return }
        let base64 = imageData.base64EncodedString()
        
        print(">>> 🚀 开始发布流程...")
        
        Task {
            do {
                // 1. 上传图片换 URL
                let imgUrl = try await VisionService.uploadImage(base64: base64)
                
                // 2. 发布
                let success = try await XHSService.publish(
                    title: publishDraftTitle,
                    content: publishDraftContent,
                    imageUrl: imgUrl
                )
                
                if success {
                    mcpManager.sendSuccess(id: reqId, sessionId: sid, text: "发布成功")
                    speakLocally(text: "发布成功！")
                } else {
                    mcpManager.sendError(id: reqId, sessionId: sid, message: "Publish failed")
                }
            } catch {
                print("❌ 发布失败: \(error)")
                mcpManager.sendError(id: reqId, sessionId: sid, message: "Error: \(error.localizedDescription)")
            }
            
            await MainActor.run { self.showPublishSheet = false }
            resetMcpState()
        }
    }
    
    // 旅行规划 (Triggered by Text)
    func performTravelPlanning(query: String) async {
        await MainActor.run {
            self.activeSheet = nil
            self.speakLocally(text: "收到，正在为您生成详细攻略，请稍候...")
        }
        
        do {
            let taskId = try await TravelService.submitPlan(query: query)
            print(">>> 任务ID: \(taskId)，开始轮询")
            
            // 轮询逻辑
            var attempts = 0
            while attempts < 60 {
                try await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                if let html = try? await TravelService.checkStatus(taskId: taskId) {
                    await MainActor.run {
                        self.generatedHtml = html
                        self.activeSheet = .htmlResult
                        self.speakLocally(text: "攻略已生成，请查看。")
                    }
                    return
                }
                attempts += 1
            }
        } catch {
            print("Plan failed: \(error)")
        }
    }
    
    // 小红书详情
    func fetchNoteDetail(feedId: String, xsecToken: String) async {
        await MainActor.run { self.speakLocally(text: "正在加载详情...") }
        do {
            if let detail = try await XHSService.fetchDetail(feedId: feedId, xsecToken: xsecToken) {
                await MainActor.run {
                    self.selectedNoteDetail = detail
                    self.activeSheet = .xhsPublish // 复用 Publish Sheet 还是 NoteDetail Sheet 看你 UI
                    // 这里假设你有单独的 Note Detail UI
                    self.showNoteDetail = true
                }
            }
        } catch {
            print("Detail failed")
        }
    }
    
    private func resetMcpState() {
        pendingMcpRequestId = nil
        pendingMcpSessionId = nil
    }
    
    private func sendJson(_ dict: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let str = String(data: data, encoding: .utf8) {
            webSocketManager.sendText(str)
        }
    }
}

// ----------------------------------------------------------------
// MARK: - WebSocket Delegate
// ----------------------------------------------------------------

extension ChatViewModel: WebSocketManagerDelegate {
    
    func webSocketDidConnect() {
        print("WS Connected")
    }
    
    func webSocketDidDisconnect(reason: String) {
        if appState != .awaitingActivation {
//            DispatchQueue.main.async { self.appState = .connectionFailed }
            DispatchQueue.main.async {
                print(">>> ⚠️ [WS] Disconnected: \(reason). Resetting audio state.")
                self.appState = .connectionFailed
                
                // ✅ 新增：断开连接时，强制停止录音和播放，重置引擎状态
                self.audioService.stopRecording()
                self.audioService.stopPlaying()
                self.isLocalSpeaking = false
            }
        }
    }
    
    func webSocketDidReceiveError(error: Error) {
        if appState != .awaitingActivation {
            DispatchQueue.main.async { self.appState = .connectionFailed }
        }
    }
    
    func webSocketDidReceiveHello(sessionId: String) {
        DispatchQueue.main.async {
            print(">>> ✅ [WS] Session Established: \(sessionId)")
            self.currentSessionId = sessionId
            // 会话建立：重连成功，清除“正在重连…”显示
            self.isReconnecting = false
            // 一键通话：冷启动/未连接时点的通话，连上后自动进通话
            if self.pendingVoiceCall {
                self.pendingVoiceCall = false
                self.voiceCallRequested = true
            }
            
            // 强制重置音频状态，防止引擎卡死
            self.audioService.stopRecording()
            
            if self.isHandsFreeMode {
                // 延迟一点点启动，给 AudioEngine 喘息机会
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startAutoListening()
                }
            } else {
                self.appState = .idle
                // 手动模式保持录音关闭，只有按住说话时才启用麦克风。
            }
            
            // 断线缓存语音补发 (手动模式才有攒包,免提模式不受影响)
            if !self.isHandsFreeMode {
                if self.isBufferingVoice {
                    // 还按着:先发已攒的包,再切回实时流 (hello 刚停过录音,补发完再重开,避免在途包被吞)
                    let buffered = self.pendingVoicePackets
                    self.pendingVoicePackets.removeAll()
                    self.pendingVoiceFlush = false
                    self.pendingVoiceDate = nil
                    self.isBufferingVoice = false
                    self.sendJson(["session_id": sessionId, "type": "listen", "state": "start", "mode": "manual"])
                    for packet in buffered {
                        self.webSocketManager.sendAudio(data: packet)
                    }
                    self.appState = .listening
                    self.audioService.startRecording()
                } else if self.pendingVoiceFlush {
                    // 已松开:整段补发 (120 秒内的才发,过期丢弃,避免旧语音突然回过来)
                    let buffered = self.pendingVoicePackets
                    self.pendingVoicePackets.removeAll()
                    self.pendingVoiceFlush = false
                    let age = self.pendingVoiceDate.map { Date().timeIntervalSince($0) } ?? 0
                    self.pendingVoiceDate = nil
                    self.isBufferingVoice = false
                    if age < 120 {
                        self.sendJson(["session_id": sessionId, "type": "listen", "state": "start", "mode": "manual"])
                        for packet in buffered {
                            self.webSocketManager.sendAudio(data: packet)
                        }
                        self.sendJson(["session_id": sessionId, "type": "listen", "state": "stop"])
                        self.appState = .idle
                    }
                }
            }
        }
    }
    
    func webSocketDidReceiveAudio(data: Data) {
        // 添加调试日志：看看是否真的收到了音频数据
        print(">>> 🎤 [Audio] Received \(data.count) bytes. Current State: \(appState)")
        
        if isLocalSpeaking {
            print(">>> ❌ [Audio] Blocked by local speaking")
            return
        } // 本地播报时不被打断
        
        // 1. 🚨 核心修复：如果在录音，必须立刻停止，否则播放声音极小或没有
        if audioService.isRecording {
            print(">>> 🛑 暂停录音，优先播放 AI 回复")
            audioService.stopRecording()
        }
        
        // 🔍 哨兵日志 2：检查是否被拦截
        if appState == .listening {
            print(">>> ❌ [Audio] Blocked because state is listening!")
            // 🚨 尝试在这里强制修正状态，死马当活马医
            DispatchQueue.main.async { self.appState = .speaking }
        }
        
        // 2. 更新状态，防止其他逻辑干扰
        DispatchQueue.main.async {
            if self.appState != .speaking {
                print(">>> 🔄 [Audio] State changed: \(self.appState) -> speaking")
                self.appState = .speaking
            }
        }
        
        if appState == .speaking {
            audioService.play(opusPacket: data)
        }
    }
    
    func webSocketDidReceiveJson(data: [String : Any]) {
        DispatchQueue.main.async {
            self.handleIncomingMessage(data)
        }
    }
    
    private func handleIncomingMessage(_ json: [String: Any]) {
        guard let type = json["type"] as? String else { return }
        
        // Update session ID if present
        if let sid = json["session_id"] as? String {
            self.currentSessionId = sid
        }
        
        switch type {
        case "stt":
            
            if self.isShowBubble {
                print(">>> 🔇 [STT] 忽略静默指令回显: \(json["text"] ?? "")")
                self.isShowBubble = false
                return
            }
            
            if let text = json["text"] as? String, !text.isEmpty {
                // 拦截旅行关键词
                if text.contains("攻略") || text.contains("行程") || text.contains("旅游") || text.contains("旅行") {
                    Task { await self.performTravelPlanning(query: text) }
                }
                
                // 简单的关键词拦截
                if text.contains("播放本地音乐") || text.contains("播放音乐") {
                    DispatchQueue.main.async {
                        SystemMusicViewModel.shared.togglePlayPause() // 播放
                    }
                } else if text.contains("下一首") {
                    DispatchQueue.main.async {
                        SystemMusicViewModel.shared.nextTrack()
                    }
                } else if text.contains("暂停播放") {
                    DispatchQueue.main.async {
                        SystemMusicViewModel.shared.togglePlayPause() // 暂停
                    }
                }
                
                // 本地打车意图：语音说“打车去XX/叫车去XX”直接打开高德打车页（打车比导航更具体，先判）
                if let dest = Self.extractTaxiDestination(from: text) {
                    Task { @MainActor in self.navigateToTaxi(destination: dest) }
                }

                // 本地导航意图：语音说“去XX/导航到XX”直接打开高德导航（不依赖服务器 MCP）
                if let dest = Self.extractNavigationDestination(from: text) {
                    Task { @MainActor in self.navigateTo(destination: dest) }
                }
                
                // 更新气泡
                if let last = messageList.last, last.type == .sent, last.text == "..." {
                    messageList[messageList.count-1] = ChatMessage(text: text, type: .sent)
                } else {
                    messageList.append(ChatMessage(text: text, type: .sent))
                }
            }
            
        case "tts":
            // 处理 HTML 流式传输
            if let state = json["state"] as? String, state == "sentence_start", let text = json["text"] as? String {
                
                // 检测 HTML 开头
                if text.contains("<!DOCTYPE html>") || text.contains("<html>") {
                    self.pendingHtmlBuffer = text
                    audioService.stopPlaying() // 停止读 HTML 代码
                    return
                }
                // 累积 HTML
                if self.pendingHtmlBuffer != nil {
                    self.pendingHtmlBuffer! += text
                    if text.contains("</html>") {
                        self.generatedHtml = self.pendingHtmlBuffer
                        self.activeSheet = .htmlResult
                        self.speakLocally(text: "页面已生成。")
                        self.pendingHtmlBuffer = nil
                    }
                    return // 不上屏气泡
                }
                
                // 过滤指令
                if text.starts(with: "%") { return }
                
                // 正常对话上屏
                if let last = messageList.last, last.type == .received {
                    let newText = last.text + text
                    messageList[messageList.count-1] = ChatMessage(id: last.id, text: newText, type: .received)
                    print("文本：\(messageList[messageList.count-1])");
                } else {
                    messageList.append(ChatMessage(text: text, type: .received))
                }
            }
            
            // 音频状态机
            if let state = json["state"] as? String {
                if state == "start" {
                    self.appState = .speaking
                    self.audioService.prepareToPlay()
                    if isHandsFreeMode { pauseAutoListeningForAI() }
                } else if state == "stop" {
                    self.audioService.stopPlaying()

                    // 服务器回的高德链接（如打车/导航链接）直接打开高德 App，不要只当文本显示
                    if let last = self.messageList.last, last.type == .received {
                        self.openAmapLinkIfPresent(in: last.text)
                    }
                    
                    // 强制显示未闭合的 HTML
                    if let html = self.pendingHtmlBuffer {
                        self.generatedHtml = html + "</html>"
                        self.activeSheet = .htmlResult
                        self.pendingHtmlBuffer = nil
                    }
                    
                    if isLocalSpeaking { return } // 让本地播报继续
                    
                    // 手动模式不预热麦克风；下一次按住说话时再启动。
                    
                    // ✅ 确保恢复录音逻辑正确
                    print(">>> ✅ AI回复完毕，恢复待机/监听")
                    
                    if isHandsFreeMode {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            self.startAutoListening()
                        }
                    } else {
                        self.appState = .idle
                    }
                }
            }
            
        case "mcp":
            if let payload = json["payload"] as? [String: Any], let sid = currentSessionId {
                // ✅ 转发给 MCP Manager
                mcpManager.handlePayload(payload, sessionId: sid)
            }
            
        default: break
        }
    }
    
}

// ----------------------------------------------------------------
// MARK: - MCP Manager Delegate
// ----------------------------------------------------------------

extension ChatViewModel: MCPManagerDelegate {
    
    func mcpDidRequestCamera(requestId: Int, sessionId: String, taskType: VisionTaskType) {
        print(">>> Delegate: Camera Requested")
        
        // 守卫：刚交付过视觉结果（15 秒内）的分析类拍照请求，几乎一定是误触发，直接忽略。
        // 背景：识别结果发给服务器后，大模型可能又把“照片”当成新的“要看”请求，再次调 take_photo，
        // 导致相机反复弹出。真正的“再看一次”请求不会在 15 秒内紧接着来；
        // 用户真想再拍照，15 秒后重说一次即可。发布小红书（.publishXhs）不受守卫影响。
        if taskType == .analyze, let last = lastVisionDeliveredAt, Date().timeIntervalSince(last) < 15 {
            print(">>> 🛡️ 守卫：刚交付视觉结果，忽略误触发的 take_photo")
            mcpManager.sendSuccess(id: requestId, sessionId: sessionId, text: "照片已分析过，无需再次拍照。")
            return
        }
        
        self.pendingMcpRequestId = requestId
        self.pendingMcpSessionId = sessionId
        self.currentVisionTask = taskType
        
        self.audioService.stopPlaying()
        self.appState = .idle
        
        // 强制主线程弹窗
        DispatchQueue.main.async {
            self.showCamera = true
        }
    }
    
    func mcpDidRequestXhsPublishPrep(title: String, content: String, requestId: Int, sessionId: String) {
        print(">>> Delegate: XHS Publish Prep")
        self.publishDraftTitle = title
        self.publishDraftContent = content
        // 触发拍照
        mcpDidRequestCamera(requestId: requestId, sessionId: sessionId, taskType: .publishXhs)
    }
    
    func mcpDidRequestUpdateUI(sheet: ActiveSheet?, message: String?) {
        DispatchQueue.main.async {
            if let sheet = sheet { self.activeSheet = sheet }
            if let msg = message { self.speakLocally(text: msg) }
        }
    }
    
    func mcpDidRequestSendFakeUserMessage(text: String) {
        guard let sid = currentSessionId else { return }
        sendJson(["session_id": sid, "type": "text", "text": text])
    }
    
    func mcpDidRequestMapUpdate(pois: [AmapPOI]?, route: AmapRoute?) {
        DispatchQueue.main.async {
            if let pois = pois { self.mapPOIs = pois }
            if let route = route { self.mapRoute = route }
        }
    }
    
    func mcpDidRequestXhsUpdate(feeds: [XhsFeed]) {
        DispatchQueue.main.async {
            self.xhsFeeds = feeds
        }
    }
}

// ----------------------------------------------------------------
// MARK: - Douyin Manager Delegate (抖音消息回调)
// ----------------------------------------------------------------

extension ChatViewModel: DouyinManagerDelegate {
    
    func douyinDidReceiveMessage(type: String, user: String, content: String) {
        if type == "like" { return }
        guard isDouyinAutoMode else { return }
        
        if appState == .speaking || appState == .connecting || isInjectingVoice { return }
        
        let now = Date()
        if now.timeIntervalSince(lastDouyinProcessTime) < 5.0 { return }
        lastDouyinProcessTime = now
        
        // ✅ 【修正1】清洗数据：去除 "[表情]" 和多余空格
        let cleanUser = user.replacingOccurrences(of: "[表情]", with: "").trimmingCharacters(in: .whitespaces)
        let cleanContent = content.replacingOccurrences(of: "[表情]", with: "").trimmingCharacters(in: .whitespaces)
        
        // 如果名字被删完了，给个默认名
        let finalUser = cleanUser.isEmpty ? "观众" : cleanUser
        
        print(">>> 🎵 [抖音消息-静默注入] \(finalUser): \(cleanContent)")
        
        DispatchQueue.main.async {
            // UI 显示也用清洗后的
            let displayMsg = "🎵 \(finalUser): \(cleanContent)"
            self.messageList.append(ChatMessage(text: displayMsg, type: .sent))
        }
        
        var prompt = ""
        switch type {
        case "gift": prompt = "快撒娇感谢！\(finalUser) 的礼物"
        case "welcome": prompt = "欢迎 \(finalUser) "
        case "chat":
            if finalUser == "Unknown" || finalUser == "未知用户" { return }
            prompt = "观众 \(finalUser) 说：\(cleanContent)"
        default: return
        }
        
        DispatchQueue.main.async {
            self.injectVoiceCommand(text: prompt)
        }
    }
    
    // 确保连接的闭包执行器
    private func ensureConnectionAndSend(action: @escaping (String) -> Void) {
        // 情况 A: 连接正常，直接发
        if webSocketManager.isConnected, let sid = currentSessionId {
            action(sid)
            return
        }
        
        // 情况 B: 连接断开，执行重连
        print("⚠️ [AutoLive] AI掉线，正在重连...")
        
        Task { @MainActor in
            // 尝试重连 OTA -> WS
            await self.connect()
            
            // 简单轮询等待 SessionID 归位
            for _ in 0..<10 { // 最多等 2 秒
                if self.webSocketManager.isConnected, let newSid = self.currentSessionId {
                    print("✅ [AutoLive] 重连成功，发送堆积消息")
                    action(newSid)
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s
            }
            print("❌ [AutoLive] 重连超时，消息丢弃")
        }
    }
    
    @MainActor
    func injectVoiceCommand(text: String, showBubble: Bool = false) {
        guard let sid = currentSessionId else { return }
        
        print(">>> 🤫 开始静默注入: \(text)")
        
        // 1. 只有 showBubble 为 true 时，才在 UI 上不显示“我发出的消息”
        if showBubble {
            isShowBubble = true
        }
        
        // 标记状态 (防止其他弹幕插嘴)
        isInjectingVoice = true
        appState = .speaking // 暂时标记为 speaking 防止 UI 变动太大
        
        // A. 准备编码器
        audioService.prepareInjectionEncoder()
        
        // B. 告诉服务器：我要说话了 (Start)
        sendJson(["session_id": sid, "type": "listen", "state": "start", "mode": "manual"])
        
        // C. 开始 TTS 生成 (不播放，只生成数据)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
//        utterance.rate = AVSpeechUtteranceMaximumSpeechRate
        utterance.volume = 1.0
        utterance.rate = 0.62
        
        // 使用 write 将音频数据写入 Buffer，而不是播放
        localSynthesizer.write(utterance) { [weak self] buffer in
            guard let self = self, let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }
            // 喂给 AudioService
            self.audioService.encodeAndSendInjectionBuffer(pcmBuffer)
        }
        
        // D. 估算结束时间并发送 Stop
        // 因为 write 没有完成回调，我们根据字数估算时长: (字数 * 0.3秒 + 0.5秒缓冲)
        let duration = Double(text.count) * 0.12 + 0.3
        
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            print(">>> 🤫 注入结束，发送 Stop")
            
            // 清理
            self.audioService.destroyInjectionEncoder()
            
            // 告诉服务器：说完了 (Stop)
            self.sendJson(["session_id": sid, "type": "listen", "state": "stop"])
            
            // 恢复状态
            self.isInjectingVoice = false
            self.appState = .connecting // 进入连接状态等待 AI 回复
        }
    }
    
    // 连接/断开抖音服务
    func connectDouyin() {
        DouyinManager.shared.connectToPushService()
    }
    
    func disconnectDouyin() {
        DouyinManager.shared.disconnect()
    }
}

