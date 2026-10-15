//
//  AppConfig.swift
//  xiaozhi
//
//  Created by Lee on 2025/12/2.
//

import Foundation

struct AppConfig {
    static let localIP = "127.0.0.1:8005" // 本地服务 (高德/中间层/微信)，替换为你自己的服务器地址
    static let visionBaseURLKey = "VisionBaseURL"
    static let zhipuAPIKeyKey = "com.xiaozhi.vision.zhipu.apiKey"
    static let zhipuModelKey = "ZhipuVisionModel"
    static let visionEndpointKey = "VisionAIEndpoint"
    static let visionModelKey = "VisionAIModel"
    static let visionAPIKeyKey = "com.xiaozhi.vision.apiKey"
    static let zhipuEndpoint = "https://open.bigmodel.cn/api/paas/v4/chat/completions"

    static var zhipuAPIKey: String {
        KeychainHelper.load(key: zhipuAPIKeyKey) ?? ""
    }

    static var zhipuModel: String {
        let value = UserDefaults.standard.string(forKey: zhipuModelKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value! : "glm-4v-flash"
    }

    static var visionEndpoint: String {
        let value = UserDefaults.standard.string(forKey: visionEndpointKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value! : zhipuEndpoint
    }

    static var visionModel: String {
        let value = UserDefaults.standard.string(forKey: visionModelKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value! : zhipuModel
    }

    static var visionAPIKey: String {
        KeychainHelper.load(key: visionAPIKeyKey) ?? zhipuAPIKey
    }

    static var visionBaseURL: String {
        let saved = UserDefaults.standard.string(forKey: visionBaseURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (saved?.isEmpty == false) ? saved! : "http://\(localIP)"
        return value.hasSuffix("/") ? String(value.dropLast()) : value
    }
    
    struct BaseURLs {
        static var xhs: String { "http://\(AppConfig.localIP)" }
        static var vision: String { AppConfig.visionBaseURL }
        static var amap: String { "http://\(AppConfig.localIP)" }
        static var middleLayer: String { "http://\(AppConfig.localIP)" }
        static var wechat: String { "http://\(AppConfig.localIP)" }
    }
}
