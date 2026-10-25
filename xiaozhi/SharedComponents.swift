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

// Live2DView 保持不变
struct Live2DView: UIViewRepresentable {
    var directoryName: String
    var jsonName: String
    var modelScale: Float = 1.0
    
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
        
        loadLive2DModel(handle, "Asset/\(directoryName)", jsonName)
        live2DSetModelScale(handle, modelScale)
        
        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        if let handle = context.coordinator.managerHandle {
             live2DSetMouthOpen(handle, audioMonitor.volume)
        }
    }
    
    func makeCoordinator() -> Coordinator { Coordinator() }
    
    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        if let handle = coordinator.managerHandle {
            destroyLive2DManager(handle)
        }
    }

    class Coordinator: NSObject {
        var managerHandle: Live2DManagerHandle?
    }
}
