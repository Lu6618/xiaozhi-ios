//
//  AppConfig.swift
//  xiaozhi
//
//  Created by Lee on 2025/12/2.
//

import Foundation

struct AppConfig {
    static let localIP = "127.0.0.1:8005" // 本地服务 (高德/中间层/微信)，替换为你自己的服务器地址

    struct BaseURLs {
        static var xhs: String { "http://\(AppConfig.localIP)" }
        static var amap: String { "http://\(AppConfig.localIP)" }
        static var middleLayer: String { "http://\(AppConfig.localIP)" }
        static var wechat: String { "http://\(AppConfig.localIP)" }
    }
}
