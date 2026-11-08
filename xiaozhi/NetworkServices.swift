//
//  NetworkServices.swift
//  xiaozhi
//
//  Created by Lee on 2025/12/2.
//

//
//  NetworkServices.swift
//  xiaozhi
//
//  Created by Lee on 2025/12/2.
//

import Foundation
import UIKit
import CoreLocation

// ----------------------------------------------------------------
// MARK: - Core Network Base
// ----------------------------------------------------------------

class NetworkService {
    static func postRequest(url: String, body: [String: Any]) async throws -> Data {
        guard let url = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let deviceId = IdentityManager.pseudoMacAddress // 或其他持久化的 ID
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        request.timeoutInterval = 60 // 设置超时
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            let responseText = String(data: data, encoding: .utf8) ?? ""
            print("❌ HTTP Error: \(httpResponse.statusCode) \(responseText)")
            throw NetworkServiceError.httpStatus(httpResponse.statusCode, responseText)
        }
        
        return data
    }
}

enum NetworkServiceError: LocalizedError {
    case httpStatus(Int, String)
    case invalidVisionAddress
    case missingZhipuAPIKey
    case invalidVisionResponse

    var errorDescription: String? {
        switch self {
        case let .httpStatus(code, message):
            return message.isEmpty ? "服务器返回 HTTP \(code)" : "服务器返回 HTTP \(code)：\(message)"
        case .invalidVisionAddress:
            return "视觉服务仍是 127.0.0.1。请在右上角设置中填写手机可访问的服务器地址。"
        case .missingZhipuAPIKey:
            return "请先在服务设置中填写视觉模型 API Key。"
        case .invalidVisionResponse:
            return "智谱视觉模型返回了无法解析的结果。"
        }
    }
}

// ----------------------------------------------------------------
// MARK: - WeChat Service
// ----------------------------------------------------------------

class WeChatService {
    static func send(to user: String, message: String) async throws {
        let _ = try await NetworkService.postRequest(
            url: "\(AppConfig.BaseURLs.wechat)/wechat/send",
            body: ["to_user": user, "message": message]
        )
    }
    
    static func getHistory(user: String) async throws -> String {
        let data = try await NetworkService.postRequest(
            url: "\(AppConfig.BaseURLs.wechat)/wechat/history",
            body: ["to_user": user]
        )
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = json["result"] as? String {
            return result
        }
        throw URLError(.cannotParseResponse)
    }
}

// ----------------------------------------------------------------
// MARK: - XiaoHongShu (XHS) Service
// ----------------------------------------------------------------

class XHSService {
    static func search(keyword: String) async throws -> [XhsFeed] {
        let data = try await NetworkService.postRequest(
            url: "\(AppConfig.BaseURLs.xhs)/api/v1/feeds/search",
            body: [
                "keyword": keyword,
                "filters": [
                    "sort_by": "综合",
                    "note_type": "不限"
                ]
            ]
        )
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataObj = json["data"] as? [String: Any],
           let feedsData = try? JSONSerialization.data(withJSONObject: dataObj["feeds"] ?? []) {
            
            let feeds = try JSONDecoder().decode([XhsFeed].self, from: feedsData)
            
            // 过滤无效数据并按点赞数排序
            let validFeeds = feeds.filter { $0.isValid }
            let sortedFeeds = validFeeds.sorted { feed1, feed2 in
                let count1 = parseLikeCount(feed1.noteCard.interactInfo.likedCount)
                let count2 = parseLikeCount(feed2.noteCard.interactInfo.likedCount)
                return count1 > count2
            }
            return sortedFeeds
        }
        return []
    }
    
    static func publish(title: String, content: String, imageUrl: String) async throws -> Bool {
        let body: [String: Any] = [
            "title": title,
            "content": content,
            "images": [imageUrl],
            "tags": []
        ]
        
        let data = try await NetworkService.postRequest(
            url: "\(AppConfig.BaseURLs.xhs)/api/v1/publish",
            body: body
        )
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let success = json["success"] as? Bool {
            return success
        }
        return false
    }
    
    static func fetchDetail(feedId: String, xsecToken: String) async throws -> XhsNoteDetail? {
        let data = try await NetworkService.postRequest(
            url: "\(AppConfig.BaseURLs.xhs)/api/v1/feeds/detail",
            body: [
                "feed_id": feedId,
                "xsec_token": xsecToken
            ]
        )
        
        let response = try JSONDecoder().decode(XhsDetailResponse.self, from: data)
        return response.data?.data?.note
    }
    
    // 辅助解析点赞数
    private static func parseLikeCount(_ str: String) -> Double {
        let cleanStr = str.replacingOccurrences(of: "+", with: "")
        if cleanStr.contains("w") {
            let numStr = cleanStr.replacingOccurrences(of: "w", with: "")
            return (Double(numStr) ?? 0) * 10000
        } else if cleanStr.contains("万") {
            let numStr = cleanStr.replacingOccurrences(of: "万", with: "")
            return (Double(numStr) ?? 0) * 10000
        } else {
            return Double(cleanStr) ?? 0
        }
    }
}

// ----------------------------------------------------------------
// MARK: - Vision (Computer Vision) Service
// ----------------------------------------------------------------

class VisionService {
    /// 统一发视觉 POST 请求：返回原始 Data，非 2xx 时抛出带状态码和服务端信息的错误
    private static func post(url: URL, body: [String: Any], apiKey: String, timeout: TimeInterval = 60) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw NetworkServiceError.httpStatus(http.statusCode, message)
        }
        return data
    }

    /// 拉取可用模型列表：GET <base>/models，返回 data[].id（已排序）
    static func fetchModels(baseURL: String, apiKey: String) async throws -> [String] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw NetworkServiceError.missingZhipuAPIKey }
        guard let urlString = AppConfig.visionURL(path: "/models", base: baseURL),
              let url = URL(string: urlString) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw NetworkServiceError.httpStatus(http.statusCode, message)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else {
            throw NetworkServiceError.invalidVisionResponse
        }
        return items.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }.sorted()
    }

    /// 一键测试连通性：用当前地址/Key/类型/模型发一次最短的纯文本请求（不发图），返回模型回复
    static func testConnectivity(baseURL: String, apiKey: String, model: String, type: VisionAPIType) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw NetworkServiceError.missingZhipuAPIKey }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { throw NetworkServiceError.invalidVisionResponse }
        guard let endpoint = AppConfig.visionEndpointURL(base: baseURL, type: type),
              let url = URL(string: endpoint) else { throw URLError(.badURL) }

        let body: [String: Any]
        switch type {
        case .chat:
            body = [
                "model": trimmedModel,
                "stream": false,
                "messages": [["role": "user", "content": "ping"]]
            ]
        case .responses:
            body = [
                "model": trimmedModel,
                "input": "ping"
            ]
        }
        let data = try await post(url: url, body: body, apiKey: key, timeout: 30)
        return try extractText(from: data, type: type)
    }

    /// 通用纯文本补全：用当前视觉配置（地址/Key/类型/模型）问模型一个问题，返回模型的纯文本回复
    /// 供生图意图识别等不需要发图的场景使用
    static func completeText(system: String, user: String, maxTokens: Int = 200) async throws -> String {
        let apiKey = AppConfig.visionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw NetworkServiceError.missingZhipuAPIKey }
        guard let url = URL(string: AppConfig.visionEndpoint) else { throw URLError(.badURL) }

        let type = AppConfig.visionAPIType
        let body: [String: Any]
        switch type {
        case .chat:
            body = [
                "model": AppConfig.visionModel,
                "stream": false,
                "max_tokens": maxTokens,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user]
                ]
            ]
        case .responses:
            body = [
                "model": AppConfig.visionModel,
                "max_output_tokens": maxTokens,
                "input": [
                    ["role": "system", "content": [["type": "input_text", "text": system]]],
                    ["role": "user", "content": [["type": "input_text", "text": user]]]
                ]
            ]
        }
        let data = try await post(url: url, body: body, apiKey: apiKey, timeout: 60)
        return try extractText(from: data, type: type)
    }

    static func analyze(base64: String) async throws -> String {
        let apiKey = AppConfig.visionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw NetworkServiceError.missingZhipuAPIKey }
        guard let url = URL(string: AppConfig.visionEndpoint) else { throw URLError(.badURL) }

        let prompt = "请用简练自然的中文描述画面内容。如果图片有文字，请同时提取重要文字。"
        let type = AppConfig.visionAPIType
        let body: [String: Any]
        switch type {
        case .chat:
            body = [
                "model": AppConfig.visionModel,
                "stream": false,
                "messages": [[
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]]
                    ]
                ]]
            ]
        case .responses:
            body = [
                "model": AppConfig.visionModel,
                "input": [[
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": prompt],
                        ["type": "input_image", "image_url": "data:image/jpeg;base64,\(base64)"]
                    ]
                ]]
            ]
        }

        let data = try await post(url: url, body: body, apiKey: apiKey)
        return try extractText(from: data, type: type)
    }

    /// 从 Chat Completions 或 Responses 的返回里取文本
    private static func extractText(from data: Data, type: VisionAPIType) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkServiceError.invalidVisionResponse
        }
        switch type {
        case .chat:
            if let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String,
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case .responses:
            if let output = json["output"] as? [[String: Any]] {
                var texts: [String] = []
                for item in output {
                    guard item["type"] as? String == "message",
                          let parts = item["content"] as? [[String: Any]] else { continue }
                    for part in parts where part["type"] as? String == "output_text" {
                        if let text = part["text"] as? String, !text.isEmpty {
                            texts.append(text)
                        }
                    }
                }
                let joined = texts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { return joined }
            }
            // 有些中转会直接给 output_text 字段
            if let text = json["output_text"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        throw NetworkServiceError.invalidVisionResponse
    }

    static func uploadImage(base64: String) async throws -> String {
        let data = try await NetworkService.postRequest(
            url: "\(AppConfig.BaseURLs.vision)/visionupload",
            body: ["image_base64": base64]
        )
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let url = json["url"] as? String {
            return url
        }
        throw URLError(.cannotParseResponse)
    }
}

// ----------------------------------------------------------------
// MARK: - Amap (Map) Service
// ----------------------------------------------------------------

class MapService {
    
    static func searchPOI(keywords: String, city: String) async throws -> (String, [AmapPOI]) {
        let data = try await NetworkService.postRequest(
            url: "\(AppConfig.BaseURLs.amap)/maps/text_search",
            body: ["keywords": keywords, "city": city]
        )
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = json["result"] as? String {
            
            var pois: [AmapPOI] = []
            if let poisData = json["data"] {
                let bytes = try? JSONSerialization.data(withJSONObject: poisData)
                if let decoded = try? JSONDecoder().decode([AmapPOI].self, from: bytes ?? Data()) {
                    pois = decoded
                }
            }
            return (result, pois)
        }
        throw URLError(.cannotParseResponse)
    }
    
    static func weatherInfo(city: String) async throws -> String {
        let data = try await NetworkService.postRequest(
            url: "\(AppConfig.BaseURLs.amap)/maps/weather",
            body: ["city": city]
        )
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = json["result"] as? String {
            return result
        }
        throw URLError(.cannotParseResponse)
    }
    
    // 1. 修改：支持 mode 参数的通用路径规划
    static func routePlanning(origin: String, dest: String, city: String?, mode: String = "driving") async throws -> (String, AmapRoute?) {
        // 智能替换起点
        var realOrigin = origin
        
        if origin == "current_location" || origin.contains("当前") || origin.contains("我") {
            do {
                // ✅ 这里调用刚才定义的方法
                let loc = try await LocationManager.shared.awaitCurrentLocation()
                realOrigin = String(format: "%.6f,%.6f", loc.longitude, loc.latitude)
                print(">>> 📍 [MapService] 获取到位置: \(realOrigin)")
            } catch {
                print(">>> ❌ [MapService] 获取位置失败: \(error)")
                // 失败了就不替换 realOrigin，后端可能会报错或用默认值
            }
        }
        
        let realCity = (city == nil || city!.isEmpty) ? LocationManager.shared.currentCity : city!
        
        // 映射 API 路径
        // 注意：这里需要你 Python 后端对应实现这些路由，或者你在 Python 端做一个统一路由分发
        // 为了方便，假设你 Python 端有对应 /maps/driving, /maps/walking, /maps/transit, /maps/bicycling
        // 如果 Python 端只有一个接口，你需要改这里
        var endpoint = "driving"
        if mode == "walking" { endpoint = "walking" }
        else if mode == "bicycling" { endpoint = "bicycling" }
        else if mode == "transit" { endpoint = "transit_integrated" } // 对应高德 API
        
        let data = try await NetworkService.postRequest(
            url: "\(AppConfig.BaseURLs.amap)/maps/\(endpoint)",
            body: [
                "origin": realOrigin,
                "destination": dest,
                "city": realCity
            ]
        )
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = json["result"] as? String {
            
            var route: AmapRoute?
            if let routeData = json["data"] {
                let bytes = try? JSONSerialization.data(withJSONObject: routeData)
                route = try? JSONDecoder().decode(AmapRoute.self, from: bytes ?? Data())
            }
            return (result, route)
        }
        
        throw URLError(.cannotParseResponse)
    }
    
    // 2. 新增：周边搜索
    static func aroundSearch(keywords: String, radius: Int = 3000) async throws -> (String, [AmapPOI]) {
        guard let loc = LocationManager.shared.currentLocation else {
            return ("无法获取当前位置，无法进行周边搜索。", [])
        }
        
        let locationStr = String(format: "%.6f,%.6f", loc.longitude, loc.latitude)
        
        let data = try await NetworkService.postRequest(
            url: "\(AppConfig.BaseURLs.amap)/maps/around_search",
            body: [
                "keywords": keywords,
                "location": locationStr,
                "radius": radius
            ]
        )
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = json["result"] as? String {
            
            var pois: [AmapPOI] = []
            if let poisData = json["data"] {
                let bytes = try? JSONSerialization.data(withJSONObject: poisData)
                if let decoded = try? JSONDecoder().decode([AmapPOI].self, from: bytes ?? Data()) {
                    pois = decoded
                }
            }
            return (result, pois)
        }
        throw URLError(.cannotParseResponse)
    }
}

// ----------------------------------------------------------------
// MARK: - 高德地图导航（打开系统高德 App）
// ----------------------------------------------------------------

/// 用 iOS URL Scheme 打开系统高德地图导航。
/// 高德 App 需安装（Info.plist 的 LSApplicationQueriesSchemes 已含 iosamap，
/// 否则 canOpenURL 永远返回 false）；未安装时返回 false，由调用方明确提示用户，不要静默失败。
/// 路线规划用名字即可（高德自己地理编码，不依赖后端）；直接开始导航需要经纬度。
/// 坐标是高德坐标系（GCJ-02），所以 dev=0。
enum AmapNavigationService {
    static var isAmapInstalled: Bool {
        guard let url = URL(string: "iosamap://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// 按名字规划路线（打开高德 App 的路线规划页，用户点“导航”即开始导航）
    @discardableResult
    static func openNavigationToName(_ name: String) -> Bool {
        guard isAmapInstalled else { return false }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "iosamap://path?sourceApplication=xiaozhi&dname=\(encoded)&dev=0&t=0") else { return false }
        UIApplication.shared.open(url)
        return true
    }

    /// 按经纬度直接开始导航
    @discardableResult
    static func openNavigation(poi: AmapPOI) -> Bool {
        guard isAmapInstalled else { return false }
        let encoded = poi.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "iosamap://navi?sourceApplication=xiaozhi&poiname=\(encoded)&lat=\(poi.latitude)&lon=\(poi.longitude)&dev=0&style=2") else { return false }
        UIApplication.shared.open(url)
        return true
    }

    /// 路线结果页用：按名字规划路线；未装高德时回退到 Apple Maps
    @discardableResult
    static func openRouteToName(_ name: String) -> Bool {
        if openNavigationToName(name) { return true }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "http://maps.apple.com/?daddr=\(encoded)") else { return false }
        UIApplication.shared.open(url)
        return true
    }

    /// POI 卡片用：有坐标直接高德导航；未装高德时回退到 Apple Maps
    @discardableResult
    static func openPOINavigation(poi: AmapPOI) -> Bool {
        if openNavigation(poi: poi) { return true }
        let encoded = poi.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "http://maps.apple.com/?q=\(encoded)") else { return false }
        UIApplication.shared.open(url)
        return true
    }
}

// ----------------------------------------------------------------
// MARK: - Travel Planner Service
// ----------------------------------------------------------------

class TravelService {
    static func submitPlan(query: String) async throws -> String {
        let data = try await NetworkService.postRequest(
            url: "\(AppConfig.BaseURLs.middleLayer)/plan/submit",
            body: ["query": query]
        )
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let taskId = json["task_id"] as? String {
            return taskId
        }
        throw URLError(.cannotParseResponse)
    }
    
    static func checkStatus(taskId: String) async throws -> String? {
        guard let url = URL(string: "\(AppConfig.BaseURLs.middleLayer)/plan/status/\(taskId)") else { return nil }
        
        // ✅ 修复：构建 Request 并添加 Header
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let deviceId = IdentityManager.pseudoMacAddress // 确保这里能取到 ID
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            // 如果还是报错，可以打印一下状态码调试
            print("Status Check Error: \(httpResponse.statusCode)")
            return nil
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let status = json["status"] as? String {
            
            if status == "completed", let html = json["html"] as? String {
                return html
            } else if status == "failed" {
                throw URLError(.cannotParseResponse)
            }
        }
        return nil // Still processing
    }
}
