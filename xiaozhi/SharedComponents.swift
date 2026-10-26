//
//  SharedComponents.swift
//  xiaozhi
//
//  Created by Lee on 2025/11/21.
//

import SwiftUI
import MetalKit
import Combine
import UIKit

// ----------------------------------------------------------------
// 1. 音量监听器 (保持不变)
// ----------------------------------------------------------------
class AudioVolumeMonitor: ObservableObject {
    @Published var volume: Float = 0.0
    
    init() {
        AudioService.shared.onVolumeUpdate = { [weak self] vol in
            self?.volume = vol
        }
    }
}

// ----------------------------------------------------------------
// 2. 聊天气泡组件
// ----------------------------------------------------------------
struct ChatBubble: View {
    let message: ChatMessage
    let screenWidth = UIScreen.main.bounds.width
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            
            if message.type == .sent { Spacer() }
            
            VStack(alignment: message.type == .sent ? .trailing : .leading, spacing: 6) {
                
                // 1. 图片显示 (独立控制尺寸)
                if let img = message.image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 200, maxHeight: 250)
                        .cornerRadius(12)
                        .padding(.bottom, 2)
                }
                
                // 2. 文本显示
                if !message.text.isEmpty {
                    Text(message.text)
                        .padding(12)
                        .background(message.type == .sent ? Color.blue.opacity(0.8) : Color.white.opacity(0.9))
                        .foregroundColor(message.type == .sent ? .white : .black)
                        .cornerRadius(16)
                        .font(.system(size: 15))
                        // ✅ 核心修复：
                        // 直接把宽度限制加在 Text 上，而不是外层的 VStack 上。
                        // 这样 Text 就能像以前一样独立计算换行了。
                        .frame(maxWidth: screenWidth * 0.75, alignment: message.type == .sent ? .trailing : .leading)
                        // 允许垂直方向无限延伸 (换行)，水平方向遵循 frame 限制
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // ❌ 注意：这里不要再给 VStack 加 frame(maxWidth) 了，让子视图自己决定宽度
            
            if message.type == .received { Spacer() }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
    }
}

// MessageRowView 保持不变
struct MessageRowView: View {
    let message: ChatMessage
    var body: some View {
        ChatBubble(message: message)
    }
}

// Live2D 控制器:SwiftUI 侧持有,供手势调用模型动作 (句柄由 Live2DView 填入)
final class Live2DController: ObservableObject {
    var handle: Live2DManagerHandle?
    
    /// 点按:随机播一个 TapBody 动作
    func tap() {
        guard let handle = handle else { return }
        live2DManagerTouchesBegan(handle)
    }
    
    /// 长按:播一个特殊动作 (TapBody 多于 1 个时取最后一个,否则随机 Idle)
    func special() {
        guard let handle = handle else { return }
        live2DPlaySpecial(handle)
    }
    
    /// 视线:x/y 为 -1~1,0 为回正
    func setLook(x: Float, y: Float) {
        guard let handle = handle else { return }
        live2DSetLook(handle, x, y)
    }
}

// Live2DView 保持不变
struct Live2DView: UIViewRepresentable {
    var directoryName: String
    var jsonName: String
    var modelScale: Float = 1.0
    var controller: Live2DController? = nil
    
    @ObservedObject var audioMonitor: AudioVolumeMonitor
    
    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.depthStencilPixelFormat = .depth32Float
        mtkView.isOpaque = false
        mtkView.backgroundColor = .clear
        
        let handle = createLive2DManager(Unmanaged.passUnretained(mtkView).toOpaque())
        context.coordinator.managerHandle = handle
        context.coordinator.controller = controller
        controller?.handle = handle
        
        loadLive2DModel(handle, "Asset/\(directoryName)", jsonName)
        live2DSetModelScale(handle, modelScale)
        
        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        if let handle = context.coordinator.managerHandle {
             live2DSetMouthOpen(handle, audioMonitor.volume)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.controller = controller
        return coordinator
    }
    
    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        if let handle = coordinator.managerHandle {
            if coordinator.controller?.handle == handle {
                coordinator.controller?.handle = nil
            }
            destroyLive2DManager(handle)
        }
    }

    class Coordinator: NSObject {
        var managerHandle: Live2DManagerHandle?
        var controller: Live2DController?
    }
}

// MARK: - 模型互动:点按 / 长按 / 拖动视线 / 粒子
struct Live2DParticle: Identifiable {
    let id = UUID()
    let position: CGPoint
    let symbol: String
}

struct Live2DInteractionModifier: ViewModifier {
    @ObservedObject var controller: Live2DController
    @State private var particles: [Live2DParticle] = []
    @State private var longPressFired = false
    @State private var lastLocation: CGPoint?
    
    private func spawn(_ symbol: String, at point: CGPoint) {
        let particle = Live2DParticle(position: point, symbol: symbol)
        particles.append(particle)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            particles.removeAll { $0.id == particle.id }
        }
    }
    
    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                lastLocation = value.location
                let x = Float(value.translation.width / 150.0)
                let y = Float(-value.translation.height / 150.0)
                controller.setLook(x: max(-1, min(1, x)), y: max(-1, min(1, y)))
            }
            .onEnded { value in
                controller.setLook(x: 0, y: 0)
                if longPressFired {
                    longPressFired = false
                } else if abs(value.translation.width) < 12 && abs(value.translation.height) < 12 {
                    controller.tap()
                    spawn(["❤️", "✨", "⭐", "💖"].randomElement() ?? "❤️", at: value.startLocation)
                }
            }
    }
    
    private var longPress: some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .onEnded { _ in
                longPressFired = true
                controller.special()
                if let point = lastLocation {
                    for dx in [-24, 0, 24] {
                        spawn("❤️", at: CGPoint(x: point.x + CGFloat(dx), y: point.y))
                    }
                }
            }
    }
    
    func body(content: Content) -> some View {
        content
            .simultaneousGesture(drag)
            .simultaneousGesture(longPress)
            .overlay {
                ZStack {
                    ForEach(particles) { particle in
                        Live2DParticleView(symbol: particle.symbol)
                            .position(particle.position)
                    }
                }
            }
    }
}

struct Live2DParticleView: View {
    let symbol: String
    @State private var offset: CGFloat = 0
    @State private var opacity: Double = 1
    
    var body: some View {
        Text(symbol)
            .font(.system(size: 28))
            .offset(y: offset)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeOut(duration: 0.9)) {
                    offset = -70
                    opacity = 0
                }
            }
    }
}

extension View {
    /// 给模型视图加互动:点按播动作并冒粒子,长按播特殊动作,拖动转视线
    func live2DInteraction(controller: Live2DController) -> some View {
        modifier(Live2DInteractionModifier(controller: controller))
    }
}
