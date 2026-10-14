//
//  xiaozhiApp.swift
//  xiaozhi
//
//  Created by Lee on 2025/11/15.
//

import SwiftUI

@main
struct xiaozhiApp: App {
    
//    init() {
//        debugPrintBundleContents()
//    }
    
    @StateObject private var chatViewModel = ChatViewModel()
    
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

