//
//  MCPManager.swift
//  xiaozhi
//
//  Created by Lee on 2025/12/2.
//

import Foundation
import UIKit
import CoreLocation

// 协议：定义 MCP 需要 UI 层配合的操作
protocol MCPManagerDelegate: AnyObject {
    func mcpDidRequestCamera(requestId: Int, sessionId: String, taskType: ChatViewModel.VisionTaskType)
    func mcpDidRequestXhsPublishPrep(title: String, content: String, requestId: Int, sessionId: String)
    
    func mcpDidRequestUpdateUI(sheet: ActiveSheet?, message: String?)
    func mcpDidRequestSendFakeUserMessage(text: String)
    
    func mcpDidRequestMapUpdate(pois: [AmapPOI]?, route: AmapRoute?)
    func mcpDidRequestXhsUpdate(feeds: [XhsFeed])
}

class MCPManager {
    
    weak var delegate: MCPManagerDelegate?
    private let webSocketManager = WebSocketManager.shared
    
    // 工具定义
    private static let toolsDefinition: [[String: Any]] = [
        [
            "name": "take_photo",
            "description": "Take a photo from the camera and analyze it. Use this when user asks to 'look at' something.",
            "inputSchema": ["type": "object", "properties": [:]]
        ],
        [
            "name": "wechat_send_message",
            "description": "给微信好友发送消息。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "to_user": ["type": "string", "description": "好友昵称"],
                    "message": ["type": "string", "description": "要发送的内容"]
                ],
                "required": ["to_user", "message"]
            ]
        ],
        [
            "name": "wechat_get_chat_history",
            "description": "获取与指定微信好友的聊天记录。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "to_user": ["type": "string", "description": "好友昵称"]
                ],
                "required": ["to_user"]
            ]
        ],
        [
            "name": "xhs_search",
            "description": "Search for notes on XiaoHongShu (Little Red Book).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "keyword": ["type": "string", "description": "Search keyword"]
                ],
                "required": ["keyword"]
            ]
        ],
        [
            "name": "publish_xhs",
            "description": "Take a photo and PUBLISH it to XiaoHongShu.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Title of the note"],
                    "content": ["type": "string", "description": "Body content"]
                ],
                "required": ["title", "content"]
            ]
        ],
        [
            "name": "maps_weather",
            "description": "Query weather forecast for a city.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "city": ["type": "string", "description": "City name"]
                ],
                "required": ["city"]
            ]
        ],
        [
            "name": "maps_text_search",
            "description": "Search for places/POIs to get address and coordinates.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "keywords": ["type": "string", "description": "Place name"],
                    "city": ["type": "string", "description": "City name"]
                ],
                "required": ["keywords", "city"]
            ]
        ],
        [
            "name": "get_user_location",
            "description": "Get user's current GPS location (coordinates and address). Call this FIRST when the user asks about nearby places ('附近', '周边', 'around me') without naming a place, then use the returned coordinates with a map search tool.",
            "inputSchema": ["type": "object", "properties": [:]]
        ],
        // 1. ✅ 综合路径规划 (驾车/公交/步行/骑行)
        [
            "name": "maps_direction",
            "description": "Plan a route between two places. Supports driving, walking, bicycling, and transit.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "origin": ["type": "string", "description": "Start place (use 'current_location' for user position)"],
                    "destination": ["type": "string", "description": "End place"],
                    "city": ["type": "string", "description": "City name (required for transit)"],
                    "mode": ["type": "string", "description": "Mode of transport. Options: driving, walking, bicycling, transit (bus/subway). Default is driving."]
                ],
                "required": ["origin", "destination"]
            ]
        ],
        // 2. ✅ 周边搜索 (附近)
        [
            "name": "maps_around_search",
            "description": "Search for POIs (like 火锅, 咖啡, 酒店) around the user's current location. Uses GPS automatically, no location needed — just pass keywords.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "keywords": ["type": "string", "description": "Keywords, e.g., 'coffee', 'hotel'"],
                    "radius": ["type": "integer", "description": "Search radius in meters. Default 3000."]
                ],
                "required": ["keywords"]
            ]
        ],
        // 3. ✅ 唤起高德导航 (Schema)
        [
            "name": "maps_open_navi",
            "description": "Generate a link to open Amap App for navigation. Use this when user asks to 'start navigation' or 'go there now'.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "destination": ["type": "string", "description": "Destination name"],
                    "latitude": ["type": "number", "description": "Destination latitude"],
                    "longitude": ["type": "number", "description": "Destination longitude"]
                ],
                "required": ["destination", "latitude", "longitude"]
            ]
        ],
        
        // 4. ✅ 唤起高德打车 (Schema)
        [
            "name": "maps_open_taxi",
            "description": "Generate a link to open Amap App for taking a taxi.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "destination": ["type": "string", "description": "Destination name"],
                    "latitude": ["type": "number", "description": "Destination latitude"],
                    "longitude": ["type": "number", "description": "Destination longitude"]
                ],
                "required": ["destination", "latitude", "longitude"]
            ]
        ],
        //本地音乐
        [
            "name": "control_local_music",
            "description": "Control local music playback on the user's phone. Actions: play, pause, next, prev.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["play", "pause", "next", "prev"], "description": "The action to perform"]
                ],
                "required": ["action"]
            ]
        ]
    ]
    
    // ----------------------------------------------------------------
    // MARK: - Handle Payload
    // ----------------------------------------------------------------
    
    func handlePayload(_ payload: [String: Any], sessionId: String) {
        guard let method = payload["method"] as? String,
              let id = payload["id"] as? Int else { return }
        
        print(">>> 🛠️ MCP Request: \(method) (id: \(id))")
        
        switch method {
        case "initialize":
            sendResponse(id: id, sessionId: sessionId, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:]],
                "serverInfo": [
                    "name": "xiaozhi-ios",
                    "version": "1.0.0"
                ]
            ])
            
        case "tools/list":
            sendResponse(id: id, sessionId: sessionId, result: [
                "tools": MCPManager.toolsDefinition
            ])
            
        case "tools/call":
            if let params = payload["params"] as? [String: Any],
               let name = params["name"] as? String {
                dispatchToolCall(name: name, params: params, id: id, sessionId: sessionId)
            }
            
        default:
            print(">>> ⚠️ Unhandled MCP method: \(method)")
        }
    }
    
    // ----------------------------------------------------------------
    // MARK: - Dispatch Tool Calls
    // ----------------------------------------------------------------
    
    private func dispatchToolCall(name: String, params: [String: Any], id: Int, sessionId: String) {
        let args = params["arguments"] as? [String: Any] ?? [:]
        
        Task {
            switch name {
            case "take_photo":
                print(">>> 📸 MCP: 请求拍照")
                await MainActor.run {
                    delegate?.mcpDidRequestCamera(requestId: id, sessionId: sessionId, taskType: .analyze)
                }
                
            case "publish_xhs":
                print(">>> 📕 MCP: 请求发布小红书")
                if let title = args["title"] as? String, let content = args["content"] as? String {
                    await MainActor.run {
                        delegate?.mcpDidRequestXhsPublishPrep(title: title, content: content, requestId: id, sessionId: sessionId)
                    }
                }
                
            case "wechat_send_message":
                if let user = args["to_user"] as? String, let msg = args["message"] as? String {
                    print(">>> 💬 MCP: 微信发送给 \(user)")
                    do {
                        try await WeChatService.send(to: user, message: msg)
                        sendSuccess(id: id, sessionId: sessionId, text: "发送成功")
                        delegate?.mcpDidRequestSendFakeUserMessage(text: "已发送微信给 \(user)：\(msg)")
                    } catch {
                        sendError(id: id, sessionId: sessionId, message: "发送失败，请检查网络")
                    }
                }
                
            case "wechat_get_chat_history":
                if let user = args["to_user"] as? String {
                    print(">>> 📜 MCP: 获取微信记录 \(user)")
                    do {
                        let history = try await WeChatService.getHistory(user: user)
                        sendSuccess(id: id, sessionId: sessionId, text: history)
                    } catch {
                        sendError(id: id, sessionId: sessionId, message: "获取失败")
                    }
                }
                
            case "xhs_search":
                if let keyword = args["keyword"] as? String {
                    print(">>> 📕 MCP: 搜索小红书 \(keyword)")
                    
                    // 1. 触发 UI 反馈 (播报语音)
                    delegate?.mcpDidRequestUpdateUI(sheet: nil, message: "正在搜索小红书：\(keyword)")
                    
                    do {
                        let feeds = try await XHSService.search(keyword: keyword)
                        
                        await MainActor.run {
                            delegate?.mcpDidRequestXhsUpdate(feeds: feeds)
                            
                            if !feeds.isEmpty {
                                delegate?.mcpDidRequestUpdateUI(sheet: .xhsResult, message: "找到 \(feeds.count) 篇笔记")
                                sendSuccess(id: id, sessionId: sessionId, text: "Found \(feeds.count) notes.")
                                delegate?.mcpDidRequestSendFakeUserMessage(text: "搜索完成，找到 \(feeds.count) 篇笔记。")
                            } else {
                                sendSuccess(id: id, sessionId: sessionId, text: "No results found.")
                                delegate?.mcpDidRequestSendFakeUserMessage(text: "没有找到相关内容。")
                            }
                        }
                    } catch {
                        sendError(id: id, sessionId: sessionId, message: "Search failed")
                    }
                }
                
            case "maps_direction":
                if let origin = args["origin"] as? String, let dest = args["destination"] as? String {
                    let city = args["city"] as? String
                    let mode = args["mode"] as? String ?? "driving"
                                        
                    print(">>> 🗺️ MCP: 路径规划 \(origin) -> \(dest) [\(mode)]")
                    
                    do {
                        let (text, route) = try await MapService.routePlanning(origin: origin, dest: dest, city: city, mode: mode)
                        
                        await MainActor.run {
                            delegate?.mcpDidRequestMapUpdate(pois: nil, route: route)
                            delegate?.mcpDidRequestUpdateUI(sheet: .mapResult, message: nil)
                        }
                        
                        sendSuccess(id: id, sessionId: sessionId, text: text)
                        delegate?.mcpDidRequestSendFakeUserMessage(text: "导航结果：\(text)")
                    } catch {
                        sendError(id: id, sessionId: sessionId, message: "Navigation failed")
                    }
                }
                
            case "maps_around_search":
                if let kw = args["keywords"] as? String {
                    let radius = args["radius"] as? Int ?? 3000
                    print(">>> 🗺️ MCP: 周边搜索 \(kw) (范围 \(radius)米)")
                    
                    do {
                        let (text, pois) = try await MapService.aroundSearch(keywords: kw, radius: radius)
                        
                        await MainActor.run {
                            delegate?.mcpDidRequestMapUpdate(pois: pois, route: nil)
                            // 可以在这里弹窗，或者只语音播报
                        }
                        
                        sendSuccess(id: id, sessionId: sessionId, text: text)
                        delegate?.mcpDidRequestSendFakeUserMessage(text: "在附近为您找到：\(text)")
                    } catch {
                        sendError(id: id, sessionId: sessionId, message: "Around search failed")
                    }
                }
                
            // 3. 新增：唤起高德导航 (maps_open_navi)
            case "maps_open_navi":
                if let destName = args["destination"] as? String,
                   let lat = args["latitude"] as? Double,
                   let lon = args["longitude"] as? Double {
                    
                    print(">>> 🚀 MCP: 唤起高德导航 -> \(destName)")
                    
                    // 构造高德 Schema
                    // iOS Schema: iosamap://navi?sourceApplication=AppName&poiname=destName&lat=lat&lon=lon&dev=0
                    let appName = "xiaozhi"
                    // URL 编码
                    let encodedName = destName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    let urlStr = "iosamap://navi?sourceApplication=\(appName)&poiname=\(encodedName)&lat=\(lat)&lon=\(lon)&dev=0&style=2"
                    
                    await MainActor.run {
                        if let url = URL(string: urlStr) {
                            if UIApplication.shared.canOpenURL(url) {
                                UIApplication.shared.open(url)
                                sendSuccess(id: id, sessionId: sessionId, text: "正在打开高德地图开始导航...")
                            } else {
                                sendSuccess(id: id, sessionId: sessionId, text: "未检测到高德地图 App，无法直接导航。")
                                delegate?.mcpDidRequestSendFakeUserMessage(text: "您似乎没有安装高德地图，我先把位置发给您。")
                            }
                        }
                    }
                }
                
            // 4. 新增：唤起高德打车 (maps_open_taxi)
            case "maps_open_taxi":
                if let destName = args["destination"] as? String,
                   let lat = args["latitude"] as? Double,
                   let lon = args["longitude"] as? Double {
                    
                    print(">>> 🚕 MCP: 唤起高德打车 -> \(destName)")
                    
                    // 获取当前位置作为起点
                    if let start = LocationManager.shared.currentLocation {
                         let urlStr = "iosamap://openFeature?featureName=Taxi&sourceApplication=xiaozhi&lat=\(lat)&lon=\(lon)&poiname=\(destName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
                         
                         await MainActor.run {
                             if let url = URL(string: urlStr) {
                                 if UIApplication.shared.canOpenURL(url) {
                                     UIApplication.shared.open(url)
                                     sendSuccess(id: id, sessionId: sessionId, text: "正在为您打开打车页面...")
                                 } else {
                                     sendSuccess(id: id, sessionId: sessionId, text: "未安装高德地图。")
                                 }
                             }
                         }
                    } else {
                        sendError(id: id, sessionId: sessionId, message: "无法获取当前位置，无法打车")
                    }
                }
                
            case "maps_text_search":
                if let kw = args["keywords"] as? String {
                    let city = args["city"] as? String ?? "成都"
                    print(">>> 🗺️ MCP: 搜索地点 \(kw)")
                    
                    do {
                        let (text, pois) = try await MapService.searchPOI(keywords: kw, city: city)
                        
                        await MainActor.run {
                            delegate?.mcpDidRequestMapUpdate(pois: pois, route: nil)
                            // 这里可以根据需求决定是否弹窗，这里暂不弹
                        }
                        
                        let reminder = "\n\n【System Instruction】: Based on these search results, please generate the HTML travel guide code now. Start with <!DOCTYPE html>."
                        sendSuccess(id: id, sessionId: sessionId, text: text + reminder)
                    } catch {
                        sendError(id: id, sessionId: sessionId, message: "Search failed")
                    }
                }
                
            case "maps_weather":
                if let city = args["city"] as? String {
                    print(">>> 🌤️ MCP: 查询天气 \(city)")
                    do {
                        let result = try await MapService.weatherInfo(city: city)
                        sendSuccess(id: id, sessionId: sessionId, text: result)
                    } catch {
                        sendError(id: id, sessionId: sessionId, message: "Weather query failed")
                    }
                }
                
            case "get_user_location":
                print(">>> 📍 MCP: 获取位置")
                do {
                    // 等定位（最多 6 秒）：旧版直接读 currentLocation，单例此前没被访问过时
                    // 位置还是 nil，直接报 GPS unavailable，小智只能反问用户在哪
                    let loc = try await LocationManager.shared.awaitCurrentLocation(timeout: 6.0)
                    let geocoder = CLGeocoder()
                    let clLoc = CLLocation(latitude: loc.latitude, longitude: loc.longitude)
                    
                    var addressStr = "未知位置"
                    
                    // 逆地理编码
                    do {
                        let placemarks = try await geocoder.reverseGeocodeLocation(clLoc)
                        if let place = placemarks.first {
                            let province = place.administrativeArea ?? ""
                            let city = place.locality ?? ""
                            let district = place.subLocality ?? ""
                            let street = place.thoroughfare ?? ""
                            let name = place.name ?? ""
                            addressStr = "\(province)\(city)\(district)\(street)\(name)"
                        }
                    } catch {
                        addressStr = LocationManager.shared.currentCity
                    }
                    
                    let info = "用户当前位置是：\(addressStr)。(坐标: \(loc.longitude), \(loc.latitude))"
                    sendSuccess(id: id, sessionId: sessionId, text: info)
                    delegate?.mcpDidRequestSendFakeUserMessage(text: "定位成功：\(addressStr)。")
                    
                } catch {
                    sendError(id: id, sessionId: sessionId, message: "无法获取当前位置，请检查定位权限后重试")
                }
                
            case "control_local_music":
                if let action = args["action"] as? String {
                    print(">>> 🎵 MCP: Music Control -> \(action)")
                    
                    await MainActor.run {
                        switch action {
                        case "play", "pause":
                            SystemMusicViewModel.shared.togglePlayPause()
                        case "next":
                            SystemMusicViewModel.shared.nextTrack()
                        case "prev":
                            SystemMusicViewModel.shared.prevTrack()
                        default: break
                        }
                        
                        // 发送成功回执 + 提示语
                        let replyText = action == "next" ? "已切歌" : (action == "play" ? "开始播放" : "已暂停")
                        sendSuccess(id: id, sessionId: sessionId, text: "Success")
                        delegate?.mcpDidRequestSendFakeUserMessage(text: "系统提示：\(replyText)")
                    }
                }
                
            default:
                print("❌ 未知工具: \(name)")
                sendError(id: id, sessionId: sessionId, code: -32601, message: "Tool not found")
            }
        }
    }
    
    // ----------------------------------------------------------------
    // MARK: - Helpers
    // ----------------------------------------------------------------
    
    func sendResponse(id: Int, sessionId: String, result: [String: Any]) {
        let response: [String: Any] = [
            "type": "mcp",
            "session_id": sessionId,
            "payload": [
                "jsonrpc": "2.0",
                "id": id,
                "result": result
            ]
        ]
        sendJson(response)
    }
    
    func sendSuccess(id: Int, sessionId: String, text: String) {
        let result: [String: Any] = [
            "content": [
                ["type": "text", "text": text]
            ],
            "isError": false
        ]
        sendResponse(id: id, sessionId: sessionId, result: result)
    }
    
    func sendError(id: Int, sessionId: String, code: Int = -1, message: String) {
        let response: [String: Any] = [
            "type": "mcp",
            "session_id": sessionId,
            "payload": [
                "jsonrpc": "2.0",
                "id": id,
                "error": ["code": code, "message": message]
            ]
        ]
        sendJson(response)
    }
    
    private func sendJson(_ dict: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let str = String(data: data, encoding: .utf8) {
            webSocketManager.sendText(str)
        }
    }
    
    // 专门处理抖音事件，将其转化为 AI 能理解的 Prompt
    func reportDouyinEvent(type: String, user: String, content: String, sessionId: String) {
        var prompt = ""
        
        switch type {
        case "gift":
            prompt = "(系统提示: 观众「\(user)」送出礼物 \(content)，请开心感谢)"
        case "welcome":
            prompt = "(系统提示: 观众「\(user)」来了，请欢迎)"
        case "chat":
            if user == "Unknown" || user == "未知用户" { return }
            prompt = "(系统提示: 观众「\(user)」说：\(content)。请简短回复)"
        default:
            return
        }
        
        // 使用 Task + Sleep 确保服务器状态机能反应过来
        print(">>> 🤖 MCP执行: [Stop旧会话] -> [Start新会话] -> [Detect文本] -> [伪造静音] -> [Stop]")
                
        DispatchQueue.main.async {
            // 这里我们借用 mcpDidRequestSendFakeUserMessage 这个通道
            // 或者你可以新增一个 delegate 方法 mcpDidRequestVoiceInjection(text: String) 更好
            // 既然不改协议，我们假定 ViewModel 能处理这个 text 并调用 injectVoiceCommand
            
            // ⚠️ 注意：这里需要 ChatViewModel 能够接收到这个请求
            // 你需要在 MCPManagerDelegate 里加一个方法，或者复用已有的
            self.delegate?.mcpDidRequestSendFakeUserMessage(text: prompt)
            
            // 实际上，建议直接在 ChatViewModel 的 douyinDidReceiveMessage 里调用 injectVoiceCommand
            // 这样 MCPManager 不需要做任何事情，保持纯净。
            // 所以，这里留空即可！
        }
    }
}
