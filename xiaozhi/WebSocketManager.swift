// 文件: WebSocketManager.swift

import Foundation
import Combine

protocol WebSocketManagerDelegate: AnyObject {
    func webSocketDidConnect()
    func webSocketDidDisconnect(reason: String)
    func webSocketDidReceiveError(error: Error)
    func webSocketDidReceiveHello(sessionId: String)
    func webSocketDidReceiveJson(data: [String: Any])
    func webSocketDidReceiveAudio(data: Data)
}

class WebSocketManager : NSObject {
    
    static let shared = WebSocketManager()
    
    weak var delegate: WebSocketManagerDelegate?
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession!
    private var heartbeatTimer: Timer?
    
    @Published var isConnected: Bool = false
    
    // 缓存参数
    private var lastURL: URL?
    private var lastToken: String?
    private var lastDeviceId: String?
    private var lastClientId: String?
    
    private var reconnectAttempts = 0
    private var isManuallyClosed = false // 标记是否是用户主动断开
    private var reconnectScheduled = false // 防止同一断线重复排期重连
    private var connectionGeneration = 0 // 连接代际：旧任务的回调（取消/关闭/收消息）不得干扰新连接
    
    override private init() {
        super.init()
    }

    // MARK: - Connect
    func connect(url: URL, token: String, deviceId: String, clientId: String) {
        // 如果任务存在，先清理旧的
        if webSocketTask != nil {
            // 这里的 cancel 可能导致 receive 报错，所以先标记手动关闭
            isManuallyClosed = true
            webSocketTask?.cancel()
            webSocketTask = nil
        }

        // 代际 +1：旧任务随后到达的取消/关闭/收消息回调一律丢弃，
        // 否则它们会误判新连接已断（回前台重连刚成功就被旧回调打回“连接失败”）。
        connectionGeneration += 1
        let generation = connectionGeneration
        
        print("Attempting to connect to WebSocket...")
        
        self.lastURL = url
        self.lastToken = token
        self.lastDeviceId = deviceId
        self.lastClientId = clientId
        
        // 重置标志位
        self.isManuallyClosed = false
        self.reconnectScheduled = false
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(deviceId, forHTTPHeaderField: "Device-Id")
        request.setValue(clientId, forHTTPHeaderField: "Client-Id")
        request.setValue("1", forHTTPHeaderField: "Protocol-Version")
        
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue.main)
        self.urlSession = session
        self.webSocketTask = session.webSocketTask(with: request)
        
        self.webSocketTask?.resume()
        
        // 开始监听
        listenForMessages(generation: generation)
    }
    
    // MARK: - Disconnect
    func disconnect(reason: String = "Manual disconnection") {
        print("Disconnecting WebSocket: \(reason)")
        
        // 1. 标记手动关闭，防止触发重连和报错日志
        isManuallyClosed = true
        isConnected = false
        reconnectScheduled = false
        stopHeartbeat()
        
        // 2. 发送关闭帧
        webSocketTask?.cancel(with: .goingAway, reason: reason.data(using: .utf8))
        webSocketTask = nil
        reconnectAttempts = 0
    }
    
    // MARK: - Listen
    private func listenForMessages(generation: Int) {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            // 旧连接的回调直接丢弃（新连接已建立，旧任务的取消报错不得干扰它）
            guard generation == self.connectionGeneration else { return }
            
            // ✅ 如果用户已经手动断开，或者是旧的 Task 回调，直接忽略
            if self.isManuallyClosed || self.webSocketTask == nil {
                return
            }
            
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    DispatchQueue.main.async {
                        self.delegate?.webSocketDidReceiveAudio(data: data)
                    }
                case .string(let text):
                    self.handleTextMessage(text)
                @unknown default:
                    break
                }
                // 继续监听下一条
                self.listenForMessages(generation: generation)
                
            case .failure(let error):
                // ✅ 只有非手动关闭导致的错误，才算异常
                if !self.isManuallyClosed {
                    print("WebSocket receive error: \(error.localizedDescription)")
                    self.handleDisconnection(reason: "Receive error")
                }
            }
        }
    }
    
    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else { return }
        
        guard let type = json["type"] as? String else { return }
        
        DispatchQueue.main.async {
            switch type {
            case "hello":
                print(">>> WebSocket RECEIVED Hello response from server.")
                if let sessionId = json["session_id"] as? String {
                    self.delegate?.webSocketDidReceiveHello(sessionId: sessionId)
                }
            case "pong":
                break
            default:
                self.delegate?.webSocketDidReceiveJson(data: json)
            }
        }
    }
    
    /// 回前台立即重连：用缓存的连接参数直接重连，不等指数退避。
    /// 从未连上过（无缓存参数）时静默返回，调用方再走完整 OTA 流程。
    func reconnectNow() {
        guard !isManuallyClosed,
              let url = lastURL, let token = lastToken,
              let deviceId = lastDeviceId, let clientId = lastClientId else { return }
        print(">>> 🔄 [WS] Foreground reconnect now")
        reconnectAttempts = 0
        reconnectScheduled = false
        connect(url: url, token: token, deviceId: deviceId, clientId: clientId)
    }
    
    private func handleDisconnection(reason: String) {
        // 旧版这里 guard isConnected else return：后台被系统静默杀掉 socket 时
        // isConnected 可能已经是 false（或 close 事件根本没到），导致一次重连都不排期，
        // 回前台后一直显示未连接。用 reconnectScheduled 去重，而不是用 isConnected 拦截。
        let wasConnected = isConnected
        isConnected = false
        stopHeartbeat()
        
        if wasConnected {
            DispatchQueue.main.async {
                self.delegate?.webSocketDidDisconnect(reason: reason)
            }
        }
        
        if !isManuallyClosed && !reconnectScheduled {
            scheduleReconnect()
        }
    }
    
    private func scheduleReconnect() {
        reconnectScheduled = true
        reconnectAttempts += 1
        // 指数退避，上限 10 秒（旧版 30 秒太长，回前台重连失败后等得太久）
        let delay = min(pow(2.0, Double(reconnectAttempts)), 10.0)
        print("Scheduling reconnect attempt \(reconnectAttempts) in \(delay) seconds.")
        
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.reconnectScheduled = false
            guard !self.isConnected, !self.isManuallyClosed else { return }
            if let url = self.lastURL, let token = self.lastToken, let deviceId = self.lastDeviceId, let clientId = self.lastClientId {
                DispatchQueue.main.async {
                    self.connect(url: url, token: token, deviceId: deviceId, clientId: clientId)
                }
            }
        }
    }
    
    // MARK: - Heartbeat
    private func startHeartbeat() {
        stopHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isConnected else { return }
            let pingMessage = "{\"type\":\"ping\"}"
            self.sendText(pingMessage)
        }
    }
    
    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }
    
    // MARK: - Send
    func sendHello() {
        let helloMessage: [String: Any] = [
            "type": "hello",
            "version": 1,
            "features": ["mcp": true],
            "transport": "websocket",
            "audio_params": [
                "format": "opus",
                "sample_rate": 16000,
                "channels": 1,
                "frame_duration": 60
            ]
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: helloMessage, options: []),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            sendText(jsonString)
        }
    }

    func sendText(_ text: String) {
        // 只有 isConnected 为 true 时才发送，避免 Socket not connected 错误
        guard isConnected, let task = webSocketTask else {
            print("⚠️ [Drop] 尝试发送文本，但 Socket 未连接！")
            return
        }
        task.send(.string(text)) { error in
            if let error = error {
                print("Error sending text: \(error.localizedDescription)")
            }
        }
    }
    
    func sendAudio(data: Data) {
        guard isConnected, let task = webSocketTask else {
            print("⚠️ [Drop] 尝试发送音频，但 Socket 未连接！")
            return
        }
        task.send(.data(data)) { error in
            if let error = error {
                print("Error sending audio: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - URLSession Delegate
extension WebSocketManager: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        // 旧任务的打开回调不得干扰新连接
        guard webSocketTask === self.webSocketTask else { return }
        print("WebSocket TCP connection established.")
        DispatchQueue.main.async {
            self.isConnected = true
            self.reconnectAttempts = 0
            self.reconnectScheduled = false
            self.sendHello()
            self.startHeartbeat()
            self.delegate?.webSocketDidConnect()
        }
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        // 旧任务的关闭回调不得干扰新连接
        guard webSocketTask === self.webSocketTask else { return }
        // 如果是我们自己手动关的，就不处理了
        if isManuallyClosed { return }
        
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "No reason"
        print("WebSocket did close with code: \(closeCode.rawValue), reason: \(reasonString)")
        self.handleDisconnection(reason: reasonString)
    }
}
