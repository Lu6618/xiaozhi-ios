import SwiftUI

struct Live2DTestView: View {
    
    @StateObject private var settings = Live2DSettings.shared
    @StateObject private var audioMonitor = AudioVolumeMonitor()
    
    // 引用全局 ViewModel
    @EnvironmentObject var chatVM: ChatViewModel
    
    // UI 状态
    @State private var douyinRoomId: String = "625662677667"
    @State private var isMonitoring = false
    @State private var showLiveConfigSheet = false // 控制配置页面的显示
    
    var body: some View {
        ZStack {
            // 1. 背景 & Live2D
            Color.white.ignoresSafeArea()
            
            Live2DView(
                directoryName: settings.currentModel.dir,
                jsonName: settings.currentModel.json,
                modelScale: settings.currentModel.scale,
                audioMonitor: audioMonitor
            )
            .ignoresSafeArea()
            .id(settings.currentModel.dir)
            
            // 2. 界面浮层
            VStack {
                // --- 顶部栏 ---
                HStack(alignment: .top) {
                    // 左侧：状态指示器 (仅在监控时或开启自动回复时显示)
//                    if isMonitoring || chatVM.isDouyinAutoMode {
//                        HStack(spacing: 8) {
//                            if isMonitoring {
//                                Circle()
//                                    .fill(Color.green)
//                                    .frame(width: 8, height: 8)
//                                    .blinkEffect() // 呼吸灯效果
//                                Text("直播监控中")
//                                    .font(.caption.bold())
//                                    .foregroundColor(.white)
//                            }
//                            
//                            if chatVM.isDouyinAutoMode {
//                                Divider().frame(height: 12).background(Color.white)
//                                Image(systemName: "brain.head.profile")
//                                    .font(.caption)
//                                    .foregroundColor(.white)
//                                Text("AI托管")
//                                    .font(.caption)
//                                    .foregroundColor(.white)
//                            }
//                        }
//                        .padding(.horizontal, 12)
//                        .padding(.vertical, 8)
//                        .background(.ultraThinMaterial)
//                        .background(Color.black.opacity(0.3)) // 加深一点背景
//                        .clipShape(Capsule())
//                        .transition(.scale.combined(with: .opacity))
//                    }
                    
//                    Spacer()
//                    
//                    // 右侧：配置按钮
//                    Button(action: {
//                        showLiveConfigSheet = true
//                    }) {
//                        Image(systemName: "antenna.radiowaves.left.and.right")
//                            .font(.system(size: 20))
//                            .foregroundColor(.white)
//                            .padding(12)
//                            .background(Color.blue)
//                            .clipShape(Circle())
//                            .shadow(radius: 4)
//                    }
                }
                .padding(.horizontal)
                .padding(.top, 10) // 避开刘海
                
                Spacer()
                
                // --- 底部模型选择器 (保持原样) ---
                modelSelector
            }
        }
        .navigationTitle("形象设置")
        .navigationBarTitleDisplayMode(.inline)
        // 3. 底部弹出配置面板 (半屏)
        .sheet(isPresented: $showLiveConfigSheet) {
            LiveConfigSheet(
                roomId: $douyinRoomId,
                isMonitoring: $isMonitoring,
                isAutoMode: $chatVM.isDouyinAutoMode,
                onToggleMonitor: toggleMonitoring
            )
            .presentationDetents([.height(300)]) // 只占用底部 300pt 高度
            .presentationDragIndicator(.visible)
        }
    }
    
    // 底部模型选择器组件
    var modelSelector: some View {
        VStack(spacing: 10) {
            Text("选择默认助手")
                .font(.subheadline)
                .foregroundColor(.gray)
                .padding(.top, 10)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 15) {
                    ForEach(ALL_MODELS) { model in
                        Button(action: {
                            withAnimation { settings.selectModel(model) }
                        }) {
                            Text(model.name)
                                .fontWeight(.bold)
                                .foregroundColor(settings.currentModel.dir == model.dir ? .white : .black)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 16)
                                .background(settings.currentModel.dir == model.dir ? Color.blue : Color(UIColor.systemGray6))
                                .cornerRadius(20)
                                .shadow(color: .black.opacity(0.1), radius: 3)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
        }
        .background(.ultraThinMaterial)
        .cornerRadius(20, corners: [.topLeft, .topRight]) // 只圆角上方
        .ignoresSafeArea(edges: .bottom)
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
                chatVM.speakLocally(text: "正在连接直播间...")
                // 启动后自动关闭配置页
                showLiveConfigSheet = false
            }
        }
    }
}

// MARK: - 子视图：配置面板
struct LiveConfigSheet: View {
    @Binding var roomId: String
    @Binding var isMonitoring: Bool
    @Binding var isAutoMode: Bool
    var onToggleMonitor: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("抖音直播配置")
                .font(.title2.bold())
                .padding(.top)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("直播间 ID")
                    .font(.caption)
                    .foregroundColor(.gray)
                
                HStack {
                    Image(systemName: "hashtag")
                        .foregroundColor(.gray)
                    TextField("输入数字ID", text: $roomId)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.plain)
                }
                .padding()
                .background(Color(UIColor.systemGray6))
                .cornerRadius(12)
            }
            
            Toggle(isOn: $isAutoMode) {
                HStack {
                    Image(systemName: "brain.head.profile")
                        .foregroundColor(.purple)
                    VStack(alignment: .leading) {
                        Text("AI 自动托管")
                            .font(.headline)
                        Text("自动读取弹幕并回复")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(.vertical, 5)
            
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
                .cornerRadius(14)
            }
            
            Spacer()
        }
        .padding(.horizontal)
    }
}

// MARK: - 辅助：呼吸灯动画 & 圆角扩展
extension View {
    func blinkEffect() -> some View {
        self.modifier(BlinkEffect())
    }
    
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct BlinkEffect: ViewModifier {
    @State private var isOn = false
    func body(content: Content) -> some View {
        content
            .opacity(isOn ? 1 : 0.4)
            .onAppear {
                withAnimation(.easeInOut(duration: 1).repeatForever()) {
                    isOn = true
                }
            }
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}
