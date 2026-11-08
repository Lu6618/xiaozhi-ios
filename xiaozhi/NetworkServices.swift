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

    var errorDescription: String? {
        switch self {
        case let .httpStatus(code, message):
            return message.isEmpty ? "服务器返回 HTTP \(code)" : "服务器返回 HTTP \(code)：\(message)"
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
        // 先等定位（最多 6 秒）：旧版直接读 currentLocation，单例没被访问过时是 nil，
        // 直接返回“无法获取当前位置”，小智只能反问用户在哪
        let loc: CLLocationCoordinate2D
        do {
            loc = try await LocationManager.shared.awaitCurrentLocation(timeout: 6.0)
        } catch {
            return ("无法获取当前位置，请检查定位权限后重试。", [])
        }
        
        let locationStr = String(format: "%.6f,%.6f", loc.longitude, loc.latitude)
        
        // 走 MCP Worker 的高德工具：本机 http://127.0.0.1 后端在真机上不可达（build 105 已确认），
        // 高德 Key 只在 Worker 的 secret 里，App 不直接调 restapi.amap.com
        let data = try await NetworkService.postRequest(
            url: "https://mcp.698668.xyz/tool-call",
            body: [
                "name": "amap_poi_search",
                "arguments": [
                    "keywords": keywords,
                    "location": locationStr,
                    "radius": radius
                ]
            ]
        )
        
        // Worker 返回 {"result": "精简中文…"}；POI 结构化数据不在返回里，语音播报只用文本
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = json["result"] as? String {
            return (result, [])
        }
        throw URLError(.cannotParseResponse)
    }
}

// ----------------------------------------------------------------
// MARK: - 本机地理编码（CLGeocoder，不依赖本地后端）
// ----------------------------------------------------------------

/// On-device geocoding: resolves a place name to coordinates without the
/// local backend (127.0.0.1:8005, unreachable on a real phone).
/// CLGeocoder returns WGS-84; Amap wants GCJ-02, so convert (standard
/// China offset algorithm; outside China the coordinates pass through).
enum LocalGeocoder {
    /// Place name -> GCJ-02 coordinate. Nil on failure (no network / no match).
    static func geocode(_ address: String) async -> CLLocationCoordinate2D? {
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await withThrowingTaskGroup(of: [CLPlacemark].self) { group in
                group.addTask {
                    try await geocoder.geocodeAddressString(address)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 6_000_000_000)
                    return []
                }
                let first = try await group.next() ?? []
                group.cancelAll()
                return first
            }
            guard let location = placemarks.first?.location else { return nil }
            return wgs84ToGCJ02(location.coordinate)
        } catch {
            return nil
        }
    }

    /// WGS-84 -> GCJ-02 (standard algorithm; no offset outside China).
    static func wgs84ToGCJ02(_ coord: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard coord.longitude >= 72.004 && coord.longitude <= 137.8347
                && coord.latitude >= 0.8293 && coord.latitude <= 55.8271 else {
            return coord
        }
        let a = 6378245.0
        let ee = 0.00669342162296594323
        let dLat = transformLat(lon: coord.longitude - 105.0, lat: coord.latitude - 35.0)
        let dLon = transformLon(lon: coord.longitude - 105.0, lat: coord.latitude - 35.0)
        let radLat = coord.latitude / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        let mgLat = coord.latitude + (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        let mgLon = coord.longitude + (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)
        return CLLocationCoordinate2D(latitude: mgLat, longitude: mgLon)
    }

    private static func transformLat(lon x: Double, lat y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * .pi) + 320 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLon(lon x: Double, lat y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return ret
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

    /// 打车：按名字打开高德打车页（高德自己解析地名）
    @discardableResult
    static func openTaxiToName(_ name: String) -> Bool {
        guard isAmapInstalled else { return false }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "amapuri://drive/takeTaxi?sourceApplication=xiaozhi&dname=\(encoded)") else { return false }
        UIApplication.shared.open(url)
        return true
    }

    /// 打车：有坐标时直接打开高德打车页（带目的地坐标，高德用当前位置当起点）
    @discardableResult
    static func openTaxi(poi: AmapPOI) -> Bool {
        guard isAmapInstalled else { return false }
        let encoded = poi.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "amapuri://drive/takeTaxi?sourceApplication=xiaozhi&dlon=\(poi.longitude)&dlat=\(poi.latitude)&dname=\(encoded)") else { return false }
        UIApplication.shared.open(url)
        return true
    }

    /// 打车：按本机地理编码出的坐标打开高德打车页（带目的地坐标与名字）。
    /// 与 openTaxi(poi:) 同一个 takeTaxi 链接，只是不依赖后端 POI 对象。
    @discardableResult
    static func openTaxiToCoordinate(name: String, latitude: Double, longitude: Double) -> Bool {
        guard isAmapInstalled else { return false }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "amapuri://drive/takeTaxi?sourceApplication=xiaozhi&dlon=\(longitude)&dlat=\(latitude)&dname=\(encoded)") else { return false }
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
