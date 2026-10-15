//
//  CameraView.swift
//  xiaozhi
//
//  Created by Lee on 2025/11/23.
//

import SwiftUI
import AVFoundation

struct CameraView: View {
    let cameraManager = CameraManager.shared
    
    // 回调：当拍好照片后，把 Base64 传出去
    var onImageCaptured: (String) -> Void
    var onCancel: () -> Void
    
    @State private var isTakingPhoto = false
    @State private var hasCompleted = false
    
    var body: some View {
        ZStack {
            // 1. 黑色背景
            Color.black.ignoresSafeArea()
            
            // 2. 摄像头预览层
            CameraPreview(session: cameraManager.session)
                .ignoresSafeArea()
            
            // 3. UI 覆盖层
            VStack {
                // 顶部：提示文字
                Text("请将物体对准屏幕中央")
                    .foregroundColor(.white)
                    .padding(.top, 50)
                    .shadow(radius: 2)
                
                Spacer()
                
                // 底部：操作栏
                HStack(spacing: 60) {
                    // 取消按钮
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.title)
                            .foregroundColor(.white)
                            .padding(20)
                            .background(Circle().fill(Color.white.opacity(0.2)))
                    }
                    
                    // 拍照按钮
                    Button(action: {
                        takePhotoAction()
                    }) {
                        ZStack {
                            Circle()
                                .stroke(Color.white, lineWidth: 4)
                                .frame(width: 80, height: 80)
                            
                            if isTakingPhoto {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 70, height: 70)
                            }
                        }
                    }
                    .disabled(isTakingPhoto)
                    
                    // 占位，保持平衡
                    Color.clear.frame(width: 60, height: 60)
                }
                .padding(.bottom, 50)
            }
        }
        .onAppear {
            cameraManager.startSession()
        }
        .onDisappear {
            cameraManager.stopSession()
        }
    }
    
    private func takePhotoAction() {
        isTakingPhoto = true
        Task {
            if let base64 = await cameraManager.takePhoto(), !hasCompleted {
                hasCompleted = true
                cameraManager.stopSession()
                // 拍照成功
                onImageCaptured(base64)
            } else {
                isTakingPhoto = false
            }
        }
    }
}

// 将 UIKit 的预览层包装给 SwiftUI 使用
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: UIScreen.main.bounds)
        view.backgroundColor = .black
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.frame
        
        view.layer.addSublayer(previewLayer)
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
}
