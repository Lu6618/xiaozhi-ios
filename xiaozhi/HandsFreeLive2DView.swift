import SwiftUI

struct HandsFreeLive2DView: View {
    // 使用 @StateObject 确保 ViewModel 生命周期跟随这个 View
//    @StateObject private var chatVM = ChatViewModel()
    @ObservedObject var chatVM: ChatViewModel
    @StateObject private var audioMonitor = AudioVolumeMonitor()
    @StateObject private var live2DController = Live2DController()
    
    // 用于返回上一页
    @Environment(\.presentationMode) var presentationMode
    
    // 监听全局设置
    @StateObject private var settings = Live2DSettings.shared
    
    // MARK: - 🆕 新增状态
    @State private var douyinRoomId: String = "" // 默认房间号
    @State private var isMonitoring = false
    @State private var showLiveConfigSheet = false // 控制配置页显示
    
    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            
            // 1. Live2D 背景
            Live2DView(
                directoryName: settings.currentModel.dir,
                jsonName: settings.currentModel.json,
                modelScale: settings.currentModel.scale,
                controller: live2DController,
                audioMonitor: audioMonitor
            )
            .ignoresSafeArea()
            .offset(y: 60)
            .id(settings.currentModel.dir)
            .live2DInteraction(controller: live2DController)
            
            // 2. 界面层
            VStack {
                // --- 顶部导航栏 (修改部分) ---
                HStack(alignment: .top) {
                    // 返回按钮
                    Button(action: {
                        disconnectAndExit()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.black.opacity(0.6))
                    }
                    
                    Spacer()
                    
                    // 中间：App 状态 (聆听中/思考中)
                    StatusPill(state: chatVM.appState)
                    
                    // 🆕 右侧：直播控制区
                    HStack(spacing: 12) {
                        // 监控状态指示器 (仅在开启时显示)
                        if isMonitoring {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 6, height: 6)
                                    .blinkEffect() // 呼吸灯
                                Text("LIVE")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red.opacity(0.8))
                            .cornerRadius(4)
                        }
                        
                        // 配置按钮
                        Button(action: {
                            showLiveConfigSheet = true
                        }) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 20))
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Color.blue)
                                .clipShape(Circle())
                                .shadow(radius: 3)
                        }
                    }
                }
                .padding(.top, 50)
                .padding(.horizontal)
                
                Spacer()
                
                // 3. 聊天气泡区 (保持不变)
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(chatVM.messageList) { msg in
                                ChatBubble(message: msg)
                                    .id(msg.id)
                            }
                        }
                        .padding()
                    }
                    .frame(maxHeight: 280)
                    .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .top, endPoint: .bottom))
                    .onChange(of: chatVM.messageList.count) { _ in
                        if let last = chatVM.messageList.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                
                // 4. 底部提示文字
                Text("免提通话模式 - 直接说话即可")
                    .font(.caption)
                    .foregroundColor(.gray.opacity(0.5))
                    .padding(.bottom, 20)
            }
            
            // 搜索 Loading (保持不变)
            if chatVM.isSearching {
                Color.black.opacity(0.4).ignoresSafeArea()
                VStack(spacing: 20) {
                    ProgressView().scaleEffect(1.5).tint(.white)
                    Text("正在搜索小红书...").foregroundColor(.white).font(.headline)
                }
                .frame(width: 180, height: 130)
                .background(.ultraThinMaterial)
                .cornerRadius(20)
                .shadow(radius: 10)
            }
        }
        // 🆕 底部弹出配置面板
        .sheet(isPresented: $showLiveConfigSheet) {
            HandsFreeLiveConfigSheet(
                roomId: $douyinRoomId,
                isMonitoring: $isMonitoring,
                isAutoMode: $chatVM.isDouyinAutoMode,
                onToggleMonitor: toggleMonitoring
            )
            .presentationDetents([.height(320)]) // 只占用底部一部分
            .presentationDragIndicator(.visible)
        }
        // 拍照/发布 Sheet (保持不变)
        .fullScreenCover(isPresented: $chatVM.showCamera) {
            CameraView(
                onImageCaptured: { base64 in chatVM.processCapturedImage(base64Str: base64) },
                onCancel: { chatVM.cancelCamera() }
            )
        }
        .sheet(item: $chatVM.activeSheet) { item in
            switch item {
                case .xhsResult: XhsResultView(viewModel: chatVM)
                case .xhsPublish:
                    XhsPublishView(
                        image: chatVM.publishDraftImage,
                        title: $chatVM.publishDraftTitle,
                        content: $chatVM.publishDraftContent,
                        onPublish: { finalImage in chatVM.confirmPublish(finalImage: finalImage) },
                        onCancel: { chatVM.showPublishSheet = false; chatVM.cancelCamera() }
                    )
                case .mapResult: MapResultView(pois: chatVM.mapPOIs, route: chatVM.mapRoute)
                case .htmlResult:
                    if let html = chatVM.generatedHtml { WebResultView(htmlContent: html) } else { Text("HTML 内容为空") }
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            print(">>> 进入 Live2D 免提模式")
            chatVM.setMode(handsFree: true)
            Task { await chatVM.connect() }
        }
        .onDisappear {
            print(">>> 离开 Live2D 免提模式")
            disconnectAndExit()
        }
    }
    
    // 退出清理逻辑
    func disconnectAndExit() {
        // 停止连接
//        chatVM.disconnect()
        
        chatVM.isHandsFreeMode = false
                
        // ✅ 2. 告诉 ViewModel 我们要回去了
        // ViewModel 会负责把麦克风保留在开启状态，但停止发送数据
        chatVM.prepareForManualMode()
        
        if isMonitoring {
            chatVM.disconnectDouyin()
        }
        presentationMode.wrappedValue.dismiss()
    }
    
    // 切换监控逻辑
    func toggleMonitoring() {
        if isMonitoring {
            Task {
                await DouyinManager.shared.stopMonitor()
                chatVM.disconnectDouyin()
                isMonitoring = false
                chatVM.speakLocally(text: "直播监控已停止")
            }
        } else {
            Task {
                await DouyinManager.shared.startMonitor(roomId: douyinRoomId)
                chatVM.connectDouyin()
                isMonitoring = true
                chatVM.speakLocally(text: "正在连接直播间 \(douyinRoomId)")
                showLiveConfigSheet = false // 启动后自动收起
            }
        }
    }
}

// -----------------------------------------------------------
// MARK: - 🆕 配置面板组件
// -----------------------------------------------------------

struct HandsFreeLiveConfigSheet: View {
    @Binding var roomId: String
    @Binding var isMonitoring: Bool
    @Binding var isAutoMode: Bool
    var onToggleMonitor: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("直播助手").font(.title2.bold())
                Spacer()
                if isMonitoring {
                    Text("运行中").font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.green.opacity(0.2)).foregroundColor(.green).cornerRadius(4)
                }
            }
            .padding(.top)
            
            // 输入框
            VStack(alignment: .leading, spacing: 8) {
                Text("直播间 ID").font(.caption).foregroundColor(.gray)
                HStack {
                    Image(systemName: "number").foregroundColor(.gray)
                    TextField("输入直播间数字ID", text: $roomId)
                        .keyboardType(.numberPad)
                        // ✅ 新增：添加清除按钮
                        .overlay(
                            Button(action: { roomId = "" }) {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.gray)
                            }
                            .padding(.trailing, 8)
                            .opacity(roomId.isEmpty ? 0 : 1)
                        , alignment: .trailing)
                }
                .padding()
                .background(Color(UIColor.systemGray6))
                .cornerRadius(12)
            }
            
            // AI 开关
            Toggle(isOn: $isAutoMode) {
                HStack {
                    Image(systemName: "brain.head.profile").foregroundColor(.purple)
                    VStack(alignment: .leading) {
                        Text("AI 自动接管")
                            .font(.headline)
                        Text("自动读取弹幕并进行语音回复")
                            .font(.caption).foregroundColor(.gray)
                    }
                }
            }
            .padding(.vertical, 5)
            
            // 按钮
            Button(action: onToggleMonitor) {
                HStack {
                    Image(systemName: isMonitoring ? "stop.fill" : "play.fill")
                    Text(isMonitoring ? "停止监控" : "开始监控")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(isMonitoring ? Color.red : Color.blue)
                .foregroundColor(.white)
                .cornerRadius(16)
            }
            Spacer()
        }
        .padding(.horizontal)
        .background(Color.white)
        .onTapGesture {
            hideKeyboard()
        }
    }
    
    // 辅助函数：收起键盘
    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// -----------------------------------------------------------
// MARK: - 辅助组件 (状态胶囊 & 呼吸动画)
// -----------------------------------------------------------

struct StatusPill: View {
    let state: AppState
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .blinkEffect(shouldBlink: state == .listening || state == .speaking)
            
            Text(statusText)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
    }
    
    var statusColor: Color {
        switch state {
        case .listening: return .green
        case .speaking: return .blue
        case .connecting: return .yellow
        case .connectionFailed: return .red
        default: return .gray
        }
    }
    
    var statusText: String {
        switch state {
        case .listening: return "聆听中..."
        case .speaking: return "回复中..."
        case .connecting: return "连接中..."
        case .connectionFailed: return "连接断开"
        default: return "待机"
        }
    }
}

// 呼吸动画扩展
extension View {
    func blinkEffect(shouldBlink: Bool = true) -> some View {
        self.modifier(BlinkModifier(shouldBlink: shouldBlink))
    }
}

struct BlinkModifier: ViewModifier {
    var shouldBlink: Bool
    @State private var isOn = false
    
    func body(content: Content) -> some View {
        content
            .opacity(shouldBlink && isOn ? 0.3 : 1)
            .onAppear {
                if shouldBlink {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever()) {
                        isOn = true
                    }
                }
            }
            .onChange(of: shouldBlink) { newValue in
                if newValue {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever()) {
                        isOn = true
                    }
                } else {
                    isOn = false // 停止
                }
            }
    }
}
