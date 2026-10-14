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
    
    @Published var messageList: [ChatMessage] = []
    @Published var appState: AppState = .connecting
    @Published var showActivationAlert = false
    @Published var activationMessage = ""
    @Published var isHandsFreeMode: Bool = false
    
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
    private var activationPollingTask: Task<Void, Never>?
    
    // MCP Pending States (等待拍照)
    private var pendingMcpRequestId: Int?
    private var pendingMcpSessionId: String?
    private var currentVisionTask: VisionTaskType = .analyze
    
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
            if self.appState == .listening || self.isInjectingVoice {
                self.webSocketManager.sendAudio(data: opusData)
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
                    // ✅ 【新增】连接成功后，在后台静默启动音频引擎
                    // 这样用户按按钮时，引擎已经是启动状态，就不会卡手势了
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        print(">>> 🎤 麦克风全时待命模式已启动")
                        if !self.audioService.isRecording {
                            self.audioService.startRecording()
                        }
                        print(">>> ✅ [Background] 麦克风已就绪，等待用户按键")
                    }
                
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
        
        // 2. 只有 ViewModel 才有权限控制 audioService 和 appState
        audioService.stopRecording()
        audioService.stopPlaying()
        currentSessionId = nil
        appState = .idle
        stopPollingForActivation()
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
            
            // 仅在监听状态发送数据
            if self.appState == .listening || self.isInjectingVoice {
                self.webSocketManager.sendAudio(data: opusData)
            }
        }
        
        // 3. 停止播放
        audioService.stopPlaying()
        
        // 4. 确保麦克风开启
        print(">>> 🎤 [Recover] 检查麦克风状态...")
        if !audioService.isRecording {
            audioService.startRecording()
        }
        
        // 5. 重置状态
        isHandsFreeMode = false
        appState = .idle
    }
    
    @MainActor
    func startUserSpeech() {
        // 【核心修复】如果当前没有 SessionID，说明连接是假的或断了，立刻触发重连
        guard let sid = currentSessionId else {
            print("⚠️ [Speech] 点击了说话，但没有 SessionID，触发重连...")
            appState = .connecting
            Task { await connect() }
            return
        }
        
        // 无论如何先连接
        if !webSocketManager.isConnected {
            Task { await connect() }
            return
        }
        
        // UI 增加 "..."
        messageList.append(ChatMessage(text: "...", type: .sent))
        
        appState = .listening
        if !audioService.isRecording {
            audioService.startRecording()
        }
        
        sendJson(["session_id": sid, "type": "listen", "state": "start", "mode": "manual"])
    }
    
    
    @MainActor
    func stopUserSpeech() {
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

        guard currentSessionId != nil, webSocketManager.isConnected else {
            appState = .connecting
            Task { await connect() }
            return
        }

        messageList.append(ChatMessage(text: content, type: .sent))

        // 小智服务端的完整对话链路是 listen start -> Opus -> listen stop。
        // 直接发送 type=text 只会被部分服务端识别，因此将键盘文字转成
        // 不外放的 TTS 音频，复用原版语音对话协议。
        injectVoiceCommand(text: content, showBubble: true)
    }

    @MainActor
    func startRealtimeConversation() {
        guard currentSessionId != nil, webSocketManager.isConnected else {
            appState = .connecting
            Task { await connect() }
            return
        }

        setMode(handsFree: true)
        startAutoListening()
    }

    @MainActor
    func stopRealtimeConversation() {
        if appState == .listening {
            stopUserSpeech()
        }
        isHandsFreeMode = false
        audioService.stopRecording()
        appState = .idle
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
        
        // 2. 结束 MCP
        let currentSid = pendingMcpSessionId
        if let reqId = pendingMcpRequestId, let sid = currentSid {
            mcpManager.sendSuccess(id: reqId, sessionId: sid, text: "照片已上传，分析完成。")
        }
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
                
                // ✅ 核心修复：使用“静默注入”机制
                // 这会调用本地 TTS 生成一段音频流发给服务器，伪装成用户在说话
                // 服务器收到音频后，一定会回复
                
                let prompt = "我拍了一张照片，内容是：\(result)。请你评价一下。"
                self.injectVoiceCommand(text: prompt, showBubble: true)
                
            } catch {
                print("Vision Error: \(error)")
                if let last = self.messageList.last, last.text.contains("正在识别") {
                    self.messageList.removeLast()
                }
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.speakLocally(text: "图片识别失败：\(reason)")
            }
        }
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
            
            // 强制重置音频状态，防止引擎卡死
            self.audioService.stopRecording()
            
            if self.isHandsFreeMode {
                // 延迟一点点启动，给 AudioEngine 喘息机会
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startAutoListening()
                }
            } else {
                self.appState = .idle
                // 手动模式下，也恢复“麦克风待命”状态
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    print(">>> 🎤 [WS] Re-arming microphone for Manual Mode")
                    self.audioService.startRecording()
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
                    
                    // 强制显示未闭合的 HTML
                    if let html = self.pendingHtmlBuffer {
                        self.generatedHtml = html + "</html>"
                        self.activeSheet = .htmlResult
                        self.pendingHtmlBuffer = nil
                    }
                    
                    if isLocalSpeaking { return } // 让本地播报继续
                    
                    // ✅ 【核心修复】AI 说完话后，立刻重新激活麦克风
                    // 这样下次用户按按钮时，麦克风已经是热启动状态，反应更快
                    if !self.audioService.isRecording {
                        self.audioService.startRecording()
                    }
                    
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
