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
            return "请先在右上角设置中填写智谱 API Key。"
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
    static func analyze(base64: String) async throws -> String {
        let apiKey = AppConfig.zhipuAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw NetworkServiceError.missingZhipuAPIKey }
        guard let url = URL(string: AppConfig.zhipuEndpoint) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": AppConfig.zhipuModel,
            "stream": false,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": "请用简练自然的中文描述画面内容。如果图片有文字，请同时提取重要文字。"],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]]
                ]
            ]]
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw NetworkServiceError.httpStatus(http.statusCode, message)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NetworkServiceError.invalidVisionResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
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
