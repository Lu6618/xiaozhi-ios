//
//  xiaozhiApp.swift
//  xiaozhi
//
//  Created by Lee on 2025/11/15.
//

import SwiftUI
import AVFoundation

@main
struct xiaozhiApp: App {

    @StateObject private var chatViewModel = ChatViewModel.shared

    var body: some Scene {
        WindowGroup {
            ConversationView()
            .preferredColorScheme(.light)
            .environmentObject(chatViewModel)
            .task {
                // 首次前台启动申请一次麦克风权限（只在前台跑；intent 后台唤起不走这条路，
                // 因为后台启动时 WindowGroup 不显示，.task 不执行——后台绝不弹授权窗）。
                await requestMicrophonePermissionOnce()
            }
        }
    }

    /// 首次前台启动时申请一次麦克风权限。UserDefaults 记“已请求过”，系统弹窗只会出现一次；
    /// 已授权/已拒绝时直接记已请求，不再打扰。
    private func requestMicrophonePermissionOnce() async {
        let key = "xiaozhi.microphonePermissionRequested"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let status = AVAudioApplication.shared.recordPermission
        guard status == .undetermined else {
            UserDefaults.standard.set(true, forKey: key)
            return
        }
        UserDefaults.standard.set(true, forKey: key)
        _ = await AVAudioApplication.requestRecordPermission()
    }
    
    private func debugPrintBundleContents() {
        print("--- DEBUG: Listing Bundle Contents ---")
        
        // ★★★ 最终修正版代码 ★★★
        // Bundle.main.bundlePath 返回的是 String, 不是 String?, 所以直接赋值
        let bundlePath = Bundle.main.bundlePath
        
        print("Bundle Root Path: \(bundlePath)\n")
        
        let fileManager = FileManager.default
        
        guard let enumerator = fileManager.enumerator(atPath: bundlePath) else {
            print("Failed to create enumerator for path: \(bundlePath)")
            return
        }

        while let element = enumerator.nextObject() {
            if let path = element as? String {
                print(path)
            }
        }
        
        print("\n--- DEBUG: End of Bundle Contents ---")
    }
}

