// 文件: CameraManager.swift

import AVFoundation
import UIKit
import Combine

// ✅ 1. CameraManager 不再直接遵守 AVCapturePhotoCaptureDelegate
class CameraManager: NSObject, @unchecked Sendable {
    static let shared = CameraManager()
    
    // 公开 session 给 UI 预览层使用
    let session = AVCaptureSession()
    private var photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "camera_session_queue")
    
    // ✅ 2. 专门用来持有当前的拍照处理器，防止被提前释放
    private var currentProcessor: PhotoCaptureProcessor?
    private var isCapturing = false
    
    override init() {
        super.init()
        configureSession()
    }
    
    private func configureSession() {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                self.session.commitConfiguration()
                return
            }
            
            if self.session.canAddInput(input) {
                self.session.addInput(input)
            }
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
            }
            self.session.commitConfiguration()
        }
    }
    
    func startSession() {
        sessionQueue.async {
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }
    
    func stopSession() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }
    
    // 3. 执行拍照
    func takePhoto() async -> String? {
        return await withCheckedContinuation { continuation in
            sessionQueue.async {
                guard !self.isCapturing else { continuation.resume(returning: nil); return }
                self.isCapturing = true
                // ✅ 4. 创建一个独立的处理器来处理这次拍照
                // 这避开了 CameraManager 本身的线程隔离问题
                let processor = PhotoCaptureProcessor(continuation: continuation)
                
                // 必须持有它，否则它会被立即释放，导致回调不执行
                self.currentProcessor = processor
                
                let settings = AVCapturePhotoSettings()
                settings.flashMode = .auto
                
                // 使用 processor 作为代理，而不是 self
                self.photoOutput.capturePhoto(with: settings, delegate: processor)
            }
        }
    }
    
    // 供处理器调用，清理引用
    fileprivate func photographyDidFinish() {
        sessionQueue.async {
            self.currentProcessor = nil
            self.isCapturing = false
        }
    }
}

// ✅ 5. 独立的拍照处理器类 (解决并发报错的核心)
private class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let continuation: CheckedContinuation<String?, Never>
    
    init(continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        
        // 无论成功失败，都要通知 Manager 清理引用
        defer {
            CameraManager.shared.photographyDidFinish()
        }

        if let error = error {
            print("❌ 拍照错误: \(error)")
            continuation.resume(returning: nil)
            return
        }
        
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            continuation.resume(returning: nil)
            return
        }
        
        // 图片处理
        let fixedImage = image.fixOrientation()
        let resizedImage = fixedImage.resized(toWidth: 800)
        let compressedData = resizedImage?.jpegData(compressionQuality: 0.6)
        let base64 = compressedData?.base64EncodedString()
        
        continuation.resume(returning: base64)
    }
}

// 图片工具扩展 (保持不变)
extension UIImage {
    func resized(toWidth width: CGFloat) -> UIImage? {
        let canvasSize = CGSize(width: width, height: CGFloat(ceil(width/size.width * size.height)))
        UIGraphicsBeginImageContextWithOptions(canvasSize, false, scale)
        defer { UIGraphicsEndImageContext() }
        draw(in: CGRect(origin: .zero, size: canvasSize))
        return UIGraphicsGetImageFromCurrentImageContext()
    }
    
    func fixOrientation() -> UIImage {
        if self.imageOrientation == .up { return self }
        UIGraphicsBeginImageContextWithOptions(self.size, false, self.scale)
        self.draw(in: CGRect(origin: .zero, size: self.size))
        let normalizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return normalizedImage ?? self
    }
}
