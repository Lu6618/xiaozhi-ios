//
//  xiaozhiApp.swift
//  xiaozhi
//
//  Created by Lee on 2025/11/15.
//

import SwiftUI

@main
struct xiaozhiApp: App {

    init() {
        // build 144：App 启动时就创建 CXProvider（CallKitManager.shared），
        // 让系统尽早完成 provider 注册。Siri intent 后台唤起时，launch 先于
        // perform() 跑，provider 到发去电 transaction 时已注册，不会因“刚创建”
        // 被判 invalidAction（error 6）。Task 跳主线程：CallKitManager 是
        // @MainActor，init 里直接碰会撞隔离；launch 后毫秒内即执行，远早于
        // intent 的 perform() 到达。
        Task { @MainActor in
            _ = CallKitManager.shared
        }
    }

    @StateObject private var chatViewModel = ChatViewModel.shared
    
    var body: some Scene {
        WindowGroup {
            ConversationView()
            .preferredColorScheme(.light)
            .environmentObject(chatViewModel)
        }
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

