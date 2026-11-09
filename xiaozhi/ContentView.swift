//
//  ContentView.swift
//  xiaozhi
//
//  Created by Lee on 2025/12/2.
//

import SwiftUI

struct ContentView: View {

    @StateObject private var viewModel = ChatViewModel.shared

    // build 146 诊断：App 内 CallKit 拨打测试的结果弹窗
    @State private var callKitTestResult: String?
    @State private var showCallKitTestAlert = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 1. 聊天消息区域
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 20) {
                            ForEach(viewModel.messageList) { message in
                                MessageRowView(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding()
                    }
                    // 修正 onChange 语法 (兼容 iOS 14+)
                    .onChange(of: viewModel.messageList.last?.text) { _ in
                        if let lastId = viewModel.messageList.last?.id {
                            // 加上动画，让用户感觉到内容在变长
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                }
                
                Spacer()
                
                // 2. 搜索状态遮罩
                if viewModel.isSearching {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                        Text("正在全网搜索...")
                            .foregroundColor(.white)
                            .font(.headline)
                    }
                    .frame(width: 180, height: 130)
                    .background(.ultraThinMaterial)
                    .cornerRadius(20)
                    .shadow(radius: 10)
                }

                // 3. 底部 "按住说话" 按钮区域
                VStack {
                    SpeakButton(state: viewModel.appState) { isPressing in
                        if isPressing {
                            viewModel.startUserSpeech()
                        } else {
                            viewModel.stopUserSpeech()
                        }
                    }
                    .disabled(viewModel.appState == .connecting || viewModel.appState == .awaitingActivation)

                    // build 146 诊断：前台直接调同一条 startCallKitCall()（与 Siri 快捷指令
                    // 完全同一入口），区分两种可能：App 内成功而快捷指令失败 → 问题在
                    // intent/后台语境；App 内也报 error 6 → 问题在 provider 配置/action 本身。
                    Button("测试 CallKit 拨打") {
                        Task {
                            do {
                                try await viewModel.startCallKitCall()
                                callKitTestResult = "成功：系统通话界面已出现"
                            } catch {
                                callKitTestResult = "失败：\(error.localizedDescription)"
                            }
                            showCallKitTestAlert = true
                        }
                    }
                    .font(.footnote)
                    .foregroundColor(.blue)
                    .padding(.top, 8)
                    .alert("CallKit 拨打测试", isPresented: $showCallKitTestAlert) {
                        Button("好的") {}
                    } message: {
                        Text(callKitTestResult ?? "")
                    }
                }
                .padding()
                .background(Color(UIColor.systemGray6).ignoresSafeArea(.container, edges: .bottom))
            }
            .background(Color(UIColor.systemGray6))
            .navigationTitle("与小智的对话")
            .navigationBarTitleDisplayMode(.inline)
            
            // 全屏弹窗：相机
            .fullScreenCover(isPresented: $viewModel.showCamera) {
                CameraView(
                    onImageCaptured: { base64 in
                        viewModel.processCapturedImage(base64Str: base64)
                    },
                    onCancel: {
                        viewModel.cancelCamera()
                    }
                )
            }
            // 底部弹窗：各种结果页
            .sheet(item: $viewModel.activeSheet) { item in
                switch item {
                case .xhsResult:
                    XhsResultView(viewModel: viewModel)
                case .xhsPublish:
                    XhsPublishView(
                        image: viewModel.publishDraftImage,
                        title: $viewModel.publishDraftTitle,
                        content: $viewModel.publishDraftContent,
                        onPublish: { img in
                            viewModel.confirmPublish(finalImage: img)
                        },
                        onCancel: {
                            viewModel.activeSheet = nil
                            viewModel.cancelCamera()
                        }
                    )
                case .mapResult:
                    MapResultView(
                        pois: viewModel.mapPOIs,
                        route: viewModel.mapRoute
                    )
                case .htmlResult:
                    if let html = viewModel.generatedHtml {
                        WebResultView(htmlContent: html)
                    }
                }
            }
            // 工具栏
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        // 调试入口
                        NavigationLink(destination: Live2DTestView()) {
                            Image(systemName: "gearshape")
                                .foregroundColor(.gray)
                        }
                        
                        // 免提模式入口
                        NavigationLink(destination: HandsFreeLive2DView(chatVM: viewModel)) {
                            Image(systemName: "phone.circle.fill")
                                .font(.title2)
                                .foregroundColor(.green)
                        }
                    }
                }
            }
            // 生命周期
            .onAppear {
                print(">>> [View] 进入手动对话模式")
                viewModel.setMode(handsFree: false)
                
                // ✅ Hard Reset 策略：延时 0.5s 发起连接，确保旧连接已断开
                if !viewModel.isConnected {
                    print(">>> [View] 冷启动连接...")
                    Task { await viewModel.connect() }
                } else {
                    // 2. 如果已经连着 (从 Live2D 回来)，执行无缝切换
                    print(">>> [View] 无缝切换...")
                    viewModel.prepareForManualMode()
                }
            }
            .alert("设备等待激活", isPresented: $viewModel.showActivationAlert) {
                Button("好的") {}
            } message: {
                Text(viewModel.activationMessage)
            }
        }
    }
}

// MARK: - 修复后的按住说话按钮
// 使用 DragGesture 替代 onLongPressGesture，解决 "Gesture timed out" 问题
struct SpeakButton: View {
    let state: AppState
    let onPressingChanged: (Bool) -> Void
    
    // 内部状态，用于处理动画和逻辑
    @State private var isPressing = false
    
    @State private var feedbackGenerator = UIImpactFeedbackGenerator(style: .heavy)
    
    var body: some View {
        ZStack {
            // 背景颜色层
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .fill(backgroundColor)
                .frame(height: 50)
                .shadow(color: .black.opacity(0.1), radius: 5, y: 3)
                // 按下时的缩放动画
                .scaleEffect(isPressing ? 0.95 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isPressing)
            
            // 文字层
            Text(buttonText)
                .font(.headline)
                .foregroundColor(isDisabled ? .gray : .primary)
        }
        .frame(maxWidth: .infinity)
        // ✅ 核心修复：使用 DragGesture (minimumDistance: 0)
        // 这种手势优先级最高，不会被系统轻易取消，响应速度最快
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isDisabled && !isPressing {
                        self.isPressing = true
                        
                        // ✅ 修改 2: 触发震动
                        // 在主线程触发，确保安全
                        DispatchQueue.main.async {
                            feedbackGenerator.prepare()
                            feedbackGenerator.impactOccurred()
                        }
                        
                        onPressingChanged(true)
                    }
                }
                .onEnded { _ in
                    if isPressing {
                        self.isPressing = false
                        onPressingChanged(false)
                    }
                }
        )
        // 禁用状态下不允许交互
        .allowsHitTesting(!isDisabled)
        .opacity(isDisabled ? 0.6 : 1.0)
        .onAppear {
            feedbackGenerator.prepare()
        }
    }
    
    private var backgroundColor: Color {
        if isDisabled { return Color(UIColor.systemGray5) }
        return state == .listening ? Color(UIColor.systemGray3) : Color.white
    }
    
    private var buttonText: String {
        switch state {
        case .idle: return "按住说话"
        case .listening: return "松开结束"
        case .speaking: return "小智正在说话..."
        case .connecting: return "连接中..."
        case .awaitingActivation: return "等待激活..."
        case .connectionFailed: return "连接失败，请重试"
        }
    }
    
    private var isDisabled: Bool {
        switch state {
        case .idle, .listening: return false
        default: return true
        }
    }
}
