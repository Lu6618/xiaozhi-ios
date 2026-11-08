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

    /// 全局唯一实例：Siri 意图在后台拉起 App 时界面可能还没建好，
    /// 通话入口必须走单例，不能依赖 View 层持有的实例。
    static let shared = ChatViewModel()
    
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
        
        // 定位预热：App 启动就开始定位，用户问“附近”时 currentLocation 已有值。
        // LocationManager 单例此前只在打车/导航/MCP 工具里才被首次访问，get_user_location
        // 第一次调用时现取位置会等几秒甚至直接报 GPS unavailable，小智只能反问用户在哪。
        _ = LocationManager.shared
        LocationManager.shared.requestLocation()
        
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
        // CallKit 通话进行中且 socket 还活着：别强制重连，会打断通话。
        // （通话中 App 靠音频后台模式活着，socket 的关闭事件能正常送达，isConnected 可信；
        //  若 socket 已死，走下面的重连，hello 到达后免提通话自动恢复。）
        if isCallKitCall && webSocketManager.isConnected { return }
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
        // 相册原图常是 4032×3024，base64 有好几 MB，上传慢、容易断；
        // 先缩到最长边 1024 再 JPEG 0.8（和相机 800px / 0.6 同一思路），识别够用
        let sized: UIImage
        if max(image.size.width, image.size.height) > 1024 {
            sized = image.resized(toWidth: 1024) ?? image
        } else {
            sized = image
        }
        guard let data = sized.jpegData(compressionQuality: 0.8) else { return }
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
                // CallKit 通话等激活码：系统通话界面等不到接通，直接挂断（用户先去 App 里填六位码再打）。
                failCallKitCallIfNeeded()
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
                    // OTA 没给 websocket 地址：CallKit 通话建不起来，直接挂断系统通话。
                    failCallKitCallIfNeeded()
                }
            }
        } catch {
            print("OTA Error: \(error)")
            if activationPollingTask == nil {
                self.appState = .connectionFailed
                // OTA/连接失败：CallKit 通话建不起来，直接挂断系统通话。
                failCallKitCallIfNeeded()
            }
        }
    }
    
    @MainActor
    func disconnect() {
        // 正在 CallKit 通话：先让系统通话界面挂断（delegate 回调会再调 endCallKitCall 收尾）。
        if isCallKitCall {
            CallKitManager.shared.endCall()
            isCallKitCall = false
            pendingCallKitCall = false
            callKitCallActive = false
            callKitFailureWatchdog?.cancel()
            callKitFailureWatchdog = nil
            audioService.endCallKitAudio()
        }
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

    // ----------------------------------------------------------------
    // MARK: - CallKit 通话（Siri 后台通话，build 128）
    // ----------------------------------------------------------------
    /// CallKit 通话进行中（Siri 唤起的系统通话）。View 据此切到通话界面。
    @Published var callKitCallActive = false
    /// 当前通话是否走 CallKit（Siri 路径）。App 内通话为 false。
    private var isCallKitCall = false
    /// CallKit 通话已发起、等 hello 后进通话（未连接时）。
    private var pendingCallKitCall = false
    /// CallKit 通话中断线看门狗：socket 断了 20 秒还没恢复就挂断系统通话，避免界面卡死。
    private var callKitFailureWatchdog: Task<Void, Never>?
    /// 正在发起 CallKit 通话（防两次 intent 并发进 startCallKitCall）。
    private var isStartingCallKitCall = false

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
    /// - xiaozhi://end —— 结束通话并断开连接（CallKit 通话也一并挂断）
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
        case "end":
            disconnect()
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

    // ----------------------------------------------------------------
    // MARK: - CallKit 通话入口与收尾（Siri 后台通话，build 128）
    // ----------------------------------------------------------------

    /// Siri 入口：开始 CallKit 通话（后台跑，不打开 App）。
    /// 等系统真正递送 perform（通话界面出现）才返回——只等 request completion
    /// 就返回会导致 intent 结束、App 被挂起，perform 永远送不到、界面不出现
    /// （build 137 实测：快捷指令显示打勾完成，但始终没通话界面）。
    /// 失败（被拒/超时/通话中）时抛中文错，快捷指令会显示失败原因。
    @MainActor
    func startCallKitCall() async throws {
        guard !isStartingCallKitCall else {
            throw XiaozhiCallError(message: "正在发起通话，请稍候")
        }
        isStartingCallKitCall = true
        defer { isStartingCallKitCall = false }
        // 残留的僵尸通话：管理器里还有 UUID，但 ViewModel 并不在通话中
        // （上次去电没等到 perform，或挂断的 perform 没回来）→ 先清掉再发起，
        // 否则 guard 直接 return、什么都不发生。
        if CallKitManager.shared.isCallActive, !isCallKitCall {
            print("⚠️ CallKit stale call found (manager has UUID, ViewModel not in call), resetting")
            CallKitManager.shared.resetStaleCall()
            pendingCallKitCall = false
            callKitCallActive = false
            callKitFailureWatchdog?.cancel()
            callKitFailureWatchdog = nil
            audioService.endCallKitAudio()
        }
        guard !CallKitManager.shared.isCallActive else {
            throw XiaozhiCallError(message: "小智正在通话中")
        }
        CallKitManager.shared.delegate = self
        isCallKitCall = true
        pendingCallKitCall = false
        audioService.callKitCallActive = true
        switch await CallKitManager.shared.startOutgoingCall() {
        case .performed:
            return
        case .rejected(let message):
            throw XiaozhiCallError(message: "发起通话失败：\(message ?? "系统拒绝了请求")，请重试")
        case .timedOut:
            throw XiaozhiCallError(message: "发起通话超时，系统没有响应，请重试")
        }
    }

    /// 结束 CallKit 通话（系统界面挂断 / 通话失败时调）。
    /// 只停语音对话、不断连接（和 App 内挂断一致）；后台 socket 自然消亡，回前台重连。
    @MainActor
    func endCallKitCall() {
        isCallKitCall = false
        pendingCallKitCall = false
        callKitCallActive = false
        callKitFailureWatchdog?.cancel()
        callKitFailureWatchdog = nil
        stopRealtimeConversation()
        audioService.endCallKitAudio()
    }

    /// CallKit 通话建不起来（OTA 失败 / 需激活）：挂断系统通话。
    @MainActor
    private func failCallKitCallIfNeeded() {
        guard isCallKitCall || pendingCallKitCall else { return }
        isCallKitCall = false
        pendingCallKitCall = false
        callKitCallActive = false
        callKitFailureWatchdog?.cancel()
        callKitFailureWatchdog = nil
        audioService.endCallKitAudio()
        CallKitManager.shared.reportFailed()
    }

    /// 通话中断线看门狗：socket 断了 20 秒还没恢复就挂断系统通话，避免界面卡死。
    /// hello 到达（重连成功）或通话结束时取消。
    @MainActor
    private func startCallKitFailureWatchdog() {
        callKitFailureWatchdog?.cancel()
        callKitFailureWatchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            guard self.isCallKitCall, !self.isConnected else { return }
            self.failCallKitCallIfNeeded()
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

        injectVoiceCommand(text: content, showBubble: true)
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
        // CallKit 通话中从 App 内挂断/切回按键：同步挂断系统通话。
        // （endCallKitCall 里已先把 isCallKitCall 置 false，不会循环。）
        if isCallKitCall {
            CallKitManager.shared.endCall()
        }
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

        // 2. 抓 MCP 待回执（上传完再回；先清状态，避免重入）
        let mcpReqId = pendingMcpRequestId
        let mcpSid = pendingMcpSessionId
        resetMcpState()

        // 3. 异步调 MCP 视觉接口拿描述，再把描述（自然语言）发给小智
        let loadingMsg = ChatMessage(text: "✨ 正在识别图片内容...", type: .received)
        self.messageList.append(loadingMsg)

        Task {
            do {
                // App 自己调 MCP 的正式视觉接口（POST /vision），直接传 base64，
                // 拿到自然语言描述。链接绝不能走语音通道：TTS 把 URL 念出来、
                // 服务端 STT 再识别回来，斜杠/点/字母必然被拆乱（build 121 的教训），
                // 所以 build 121 的“发链接让小智调 vision 工具”流程彻底废弃。
                let description = try await Self.recognizeImageViaMcp(base64: base64Str)
                print(">>> 🖼️ MCP 视觉描述：\(description)")

                if let last = self.messageList.last, last.text.contains("正在识别") {
                    self.messageList.removeLast()
                }

                // 标记：刚交付过视觉结果（mcpDidRequestCamera 里的守卫用，
                // 屏蔽服务器随后误触发的 take_photo）
                self.lastVisionDeliveredAt = Date()

                // 描述是自然语言，走 TTS/STT 不会被拆坏（build 114 的老流程证实可行）。
                // showBubble 必须传 true：它的语义是反直觉的——传 true 才表示
                // “这次是静默注入”，服务器回传的 STT 转写会被 isShowBubble 吞掉、不显示气泡。
                if let reqId = mcpReqId, let sid = mcpSid {
                    // A. MCP 触发的拍照：描述直接作为工具回执发回服务器。
                    // 工具回执是“已完成的观察”，不是用户发言，不走语音，不会被 STT 拆乱。
                    mcpManager.sendSuccess(id: reqId, sessionId: sid, text: description)
                } else {
                    // B. 用户主动拍照/选图：走语音注入（injectVoiceCommand）发给小智。
                    // 语音注入是 App 里唯一能让服务器回话的路径（打字消息也走这条路）；
                    // 冷发的 {"type": "text"} 文本消息在服务端没有对应的处理器，
                    // 会被静默丢弃、小智永远不回（build 112 的教训）。
                    self.injectVoiceCommand(text: description + "你觉得怎么样？", showBubble: true)
                }

            } catch {
                print("MCP Vision Error: \(error)")
                if let last = self.messageList.last, last.text.contains("正在识别") {
                    self.messageList.removeLast()
                }
                if let reqId = mcpReqId, let sid = mcpSid {
                    // MCP 任务失败也要回执，否则服务器会一直等工具结果
                    mcpManager.sendError(id: reqId, sessionId: sid, message: "图片识别失败")
                } else {
                    let reason = Self.mcpVisionErrorMessage(error)
                    self.speakLocally(text: "图片识别失败：\(reason)")
                }
            }
        }
    }

    /// 调 MCP 的正式视觉接口（POST https://mcp.698668.xyz/vision），直接传 base64，
    /// 返回视觉模型的中文描述。最多重试 3 次（瞬时网络错误与 5xx 才重试，4xx 不重试）。
    private static func recognizeImageViaMcp(base64: String) async throws -> String {
        guard let url = URL(string: "https://mcp.698668.xyz/vision") else {
            throw URLError(.badURL)
        }
        var lastError: Error = URLError(.unknown)
        for attempt in 1...3 {
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                // 单次 90 秒：Worker 侧视觉上游超时已放宽到 60 秒，App 必须比它更宽，
                // 否则 Worker 还没回包 App 就先断了（60 秒旧值会把 Worker 的慢响应误判成超时）。
                request.timeoutInterval = 90
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["image_base64": base64])
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                if (200...299).contains(http.statusCode) {
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let result = json["result"] as? String, !result.isEmpty else {
                        throw URLError(.cannotParseResponse)
                    }
                    return result
                }
                // 4xx（鉴权、参数）不重试，直接抛
                let message = String(data: data, encoding: .utf8) ?? ""
                throw NetworkServiceError.httpStatus(http.statusCode, message)
            } catch {
                lastError = error
                guard Self.isRetryableVisionError(error), attempt < 3 else { throw error }
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000) // 1 秒、2 秒递增
            }
        }
        throw lastError
    }

    /// 只有瞬时网络错误与 5xx 才重试（与 build 119 的 VisionService.post 同一套规则）。
    private static func isRetryableVisionError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .notConnectedToInternet, .secureConnectionFailed:
                return true
            default:
                return false
            }
        }
        if case NetworkServiceError.httpStatus(let code, _) = error {
            return (500...599).contains(code)
        }
        return false
    }

    /// 按错误给中文说明，不再只报英文原文。
    private static func mcpVisionErrorMessage(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .networkConnectionLost, .notConnectedToInternet:
                return "网络连接中断，已自动重试 3 次仍失败，请检查网络后重新拍照"
            case .timedOut:
                return "识别超时，已自动重试 3 次仍失败，请检查网络后重新拍照"
            case .cannotFindHost, .cannotConnectToHost:
                return "连不上识别服务，请检查网络后重新拍照"
            case .secureConnectionFailed:
                // -1200：TLS 握手失败，3 次重试都失败说明不是瞬断。
                // 常见于本机代理/MITM 拦截了到识别服务的 TLS 连接
                // （或系统时间不对、网络本身的 TLS 有问题），所以多给一句代理提示。
                return "安全连接失败，如开了代理工具请先关掉再试，也可检查网络后重新拍照"
            default:
                break
            }
        }
        if case NetworkServiceError.httpStatus(let code, _) = error {
            return (400...499).contains(code)
                ? "识别服务返回错误（\(code)），请稍后再试"
                : "识别服务暂时不可用（\(code)），请稍后再试"
        }
        return error.localizedDescription
    }

    /// 把图片 base64 上传到 MCP 服务（POST https://mcp.698668.xyz/upload），
    /// 返回图片链接（https://mcp.698668.xyz/img/<id>）。
    /// 仅小红书发布流程（confirmPublish）在用；拍照/选图识别已改走 POST /vision
    /// 直接拿描述，不再经过上传（链接走语音通道会被 STT 拆乱）。
    private static func uploadImageToMcp(base64: String) async throws -> String {
        guard let url = URL(string: "https://mcp.698668.xyz/upload") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["image_base64": base64])
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw NetworkServiceError.httpStatus(http.statusCode, message)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let imageURL = json["url"] as? String, !imageURL.isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        return imageURL
    }

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
                // 1. 上传图片换 URL（走 MCP 服务）
                let imgUrl = try await Self.uploadImageToMcp(base64: base64)
                
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

                // CallKit 通话中掉线：先让自动重连跑（build 90 的退避），20 秒还连不上再挂断系统通话。
                if self.isCallKitCall {
                    self.startCallKitFailureWatchdog()
                }
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
            // CallKit 通话中重连成功：取消掉线看门狗。
            self.callKitFailureWatchdog?.cancel()
            self.callKitFailureWatchdog = nil
            // CallKit 通话（Siri 唤起）：不走 View 的 voiceCallRequested，直接在 ViewModel 里进通话。
            // 先 stopRecording() 重置音频状态（和下面第 4 步同义，这里先做），再进通话；
            // callKitJustStarted 让下面不再重复停录音、也不再补发 listen start。
            var callKitJustStarted = false
            if self.pendingCallKitCall {
                self.pendingCallKitCall = false
                self.pendingVoiceCall = false
                self.audioService.stopRecording()
                self.callKitCallActive = true
                self.startRealtimeConversation()
                CallKitManager.shared.reportConnected()
                callKitJustStarted = true
            } else if self.pendingVoiceCall {
                // 一键通话：冷启动/未连接时点的通话，连上后自动进通话
                self.pendingVoiceCall = false
                self.voiceCallRequested = true
            }
            
            // 强制重置音频状态，防止引擎卡死（CallKit 刚进通话时跳过，上面已起好录音）
            if !callKitJustStarted {
                self.audioService.stopRecording()
            }
            
            if self.isHandsFreeMode {
                // 延迟一点点启动，给 AudioEngine 喘息机会
                // （CallKit 刚进通话时跳过：startRealtimeConversation 已发过 listen start）
                if !callKitJustStarted {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.startAutoListening()
                    }
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
        
        // 注意：这里的 showBubble 语义是反直觉的——传 true 表示“这次是静默注入”，
        // 服务器回传的 STT 转写会被 isShowBubble 吞掉、不显示成气泡；
        // 传 false 则回显正常上屏。视觉路径必须传 true，否则描述会以蓝色气泡显示出来。
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

// ----------------------------------------------------------------
// MARK: - CallKit Manager Delegate（Siri 系统通话，build 128）
// ----------------------------------------------------------------

extension ChatViewModel: CallKitManagerDelegate {

    /// 系统接受了去电请求：开始连接（已连接就直接进通话）。
    @MainActor
    func callKitDidPerformStartCall() {
        CallKitManager.shared.reportConnecting()
        if isConnected, currentSessionId != nil {
            callKitCallActive = true
            startRealtimeConversation()
            CallKitManager.shared.reportConnected()
        } else {
            pendingCallKitCall = true
            // 20 秒内连不上（hello 未到）就挂断系统通话，避免“正在呼叫…”卡死；
            // WS 层自己会指数退避重连，hello 到达时看门狗已取消。
            startCallKitFailureWatchdog()
            Task { await connect() }
        }
    }

    /// 系统通话界面挂断：结束语音对话，界面切回（不断连接，和 App 内挂断一致）。
    @MainActor
    func callKitDidEndCall() {
        endCallKitCall()
    }

    /// 系统通话界面静音开关。
    @MainActor
    func callKitDidSetMuted(_ muted: Bool) {
        setMicrophoneMuted(muted)
    }

    /// 去电请求被系统拒绝：清理通话状态。
    @MainActor
    func callKitDidFailToStart() {
        isCallKitCall = false
        pendingCallKitCall = false
        callKitCallActive = false
        audioService.endCallKitAudio()
    }

    /// CallKit 激活了音频会话（通话开始 / 被电话打断后恢复）：
    /// 若正在免提通话且应监听但没在录，恢复录音。
    @MainActor
    func callKitAudioSessionDidActivate() {
        guard isCallKitCall, isHandsFreeMode, currentSessionId != nil,
              appState == .listening, !audioService.isRecording else { return }
        audioService.startRecording()
    }

    /// CallKit 释放了音频会话（通话结束 / 被电话打断）：暂停音频。
    @MainActor
    func callKitAudioSessionDidDeactivate() {
        audioService.stopRecording()
        audioService.stopPlaying()
    }
}

