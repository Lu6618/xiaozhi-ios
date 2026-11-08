//
//  AppConfig.swift
//  xiaozhi
//
//  Created by Lee on 2025/12/2.
//

import Foundation

/// 视觉接口类型：用户只选类型，App 按类型自动拼请求路径
enum VisionAPIType: String, CaseIterable, Identifiable {
    case chat = "chat"
    case responses = "responses"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chat: return "Chat Completions"
        case .responses: return "Responses"
        }
    }

    /// 拼在基础地址后面的请求路径
    var path: String {
        switch self {
        case .chat: return "/chat/completions"
        case .responses: return "/responses"
        }
    }
}

struct AppConfig {
    static let localIP = "127.0.0.1:8005" // 本地服务 (高德/中间层/微信)，替换为你自己的服务器地址
    static let visionBaseURLKey = "VisionBaseURL"
    static let zhipuAPIKeyKey = "com.xiaozhi.vision.zhipu.apiKey"
    static let zhipuModelKey = "ZhipuVisionModel"
    static let visionEndpointKey = "VisionAIEndpoint"
    static let visionModelKey = "VisionAIModel"
    static let visionAPIKeyKey = "com.xiaozhi.vision.apiKey"
    static let visionAPIBaseURLKey = "VisionAPIBaseURL"
    static let visionAPITypeKey = "VisionAPIType"
    static let visionPromptTemplateKey = "VisionPromptTemplate"
    /// 发给小智的识图提示词模板（默认：小智视角直接描述所见）
    static let defaultVisionPromptTemplate = "你看到了一张照片，照片里是：{description}。请自然地说说你看到了什么。"
    static let zhipuEndpoint = "https://open.bigmodel.cn/api/paas/v4/chat/completions"

    static var zhipuAPIKey: String {
        KeychainHelper.load(key: zhipuAPIKeyKey) ?? ""
    }

    static var zhipuModel: String {
        let value = UserDefaults.standard.string(forKey: zhipuModelKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value! : "glm-4v-flash"
    }

    /// 用户填的基础地址（只填 base，不用带 /chat/completions 或 /responses）
    static var visionAPIBaseURL: String {
        let value = UserDefaults.standard.string(forKey: visionAPIBaseURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value ?? ""
    }

    /// 当前选择的视觉接口类型；没选过时从旧的完整接口地址推断
    static var visionAPIType: VisionAPIType {
        if let raw = UserDefaults.standard.string(forKey: visionAPITypeKey),
           let type = VisionAPIType(rawValue: raw) {
            return type
        }
        let legacy = UserDefaults.standard.string(forKey: visionEndpointKey) ?? ""
        if legacy.hasSuffix("/responses") { return .responses }
        return .chat
    }

    /// 归一化基础地址：补 https://、去末尾斜杠、去掉已贴的完整接口后缀
    /// 例如 "agentrouter.698668.xyz" -> "https://agentrouter.698668.xyz"
    /// "https://x/v1/chat/completions" -> "https://x/v1"
    static func normalizeVisionBaseURL(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        if !value.contains("://") {
            value = "https://" + value
        }
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix("/chat/completions") {
            value = String(value.dropLast("/chat/completions".count))
        } else if value.hasSuffix("/responses") {
            value = String(value.dropLast("/responses".count))
        }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// 用基础地址拼任意子路径（例如 /models），自动处理已贴完整接口的情况
    static func visionURL(path: String, base: String) -> String? {
        let normalized = normalizeVisionBaseURL(base)
        guard !normalized.isEmpty else { return nil }
        return normalized + path
    }

    /// 用基础地址 + 类型拼出完整视觉接口地址
    static func visionEndpointURL(base: String, type: VisionAPIType) -> String? {
        let normalized = normalizeVisionBaseURL(base)
        guard !normalized.isEmpty else { return nil }
        return normalized + type.path
    }

    /// 视觉接口完整地址：优先用新版（基础地址 + 类型），否则回退到旧的完整地址或智谱默认
    static var visionEndpoint: String {
        if let endpoint = visionEndpointURL(base: visionAPIBaseURL, type: visionAPIType) {
            return endpoint
        }
        let value = UserDefaults.standard.string(forKey: visionEndpointKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value! : zhipuEndpoint
    }

    static var visionModel: String {
        let value = UserDefaults.standard.string(forKey: visionModelKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value! : zhipuModel
    }

    /// 识图后发给小智的提示词模板；没填过或被清空时用默认模板
    static var visionPromptTemplate: String {
        let value = UserDefaults.standard.string(forKey: visionPromptTemplateKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value! : defaultVisionPromptTemplate
    }

    /// 按模板拼出识图后发给小智的提示词：
    /// 模板含 {description} 时替换成识别结果；没有占位符时把识别结果拼在末尾
    static func renderVisionPrompt(description: String) -> String {
        let template = visionPromptTemplate
        if template.contains("{description}") {
            return template.replacingOccurrences(of: "{description}", with: description)
        }
        return template + " " + description
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
