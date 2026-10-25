// 文件: Live2DConfig.swift

import SwiftUI
import Combine // ✅ 必须引入这个框架，否则 @Published 和 ObservableObject 会报错

// 1. 模型数据结构
struct ModelInfo: Hashable, Identifiable {
    var id: String { dir } // 使用文件夹名作为唯一ID
    let name: String      // 显示的名字 (如: "Hiyori")
    let dir: String       // 文件夹名 (如: "Hiyori")
    let json: String      // json文件名 (如: "Hiyori.model3.json")
}

// 2. 全局模型列表配置
let ALL_MODELS = [
    ModelInfo(name: "Hiyori", dir: "Hiyori", json: "Hiyori.model3.json"),
    ModelInfo(name: "Haru", dir: "Haru", json: "Haru.model3.json"),
    ModelInfo(name: "Rice", dir: "Rice", json: "Rice.model3.json"),
    ModelInfo(name: "Mao", dir: "Mao", json: "Mao.model3.json"),
    ModelInfo(name: "Mark", dir: "Mark", json: "Mark.model3.json"),
    ModelInfo(name: "Natori", dir: "Natori", json: "Natori.model3.json"),
    ModelInfo(name: "Wanko", dir: "Wanko", json: "Wanko.model3.json"),
    ModelInfo(name: "Centaur", dir: "Centaur", json: "Centaur.model3.json")
]

// 3. 设置管理器 (负责保存和读取)
// ✅ 确保这里继承了 ObservableObject
class Live2DSettings: ObservableObject {
    
    // 单例，方便各处访问
    static let shared = Live2DSettings()
    
    // ✅ 确保使用了 @Published
    @Published var currentModel: ModelInfo {
        didSet {
            // 当模型改变时，保存到 UserDefaults
            UserDefaults.standard.set(currentModel.dir, forKey: "SelectedLive2DModelDir")
        }
    }
    
    private init() {
        // 初始化时，从 UserDefaults 读取，如果没有则默认第一个
        let savedDir = UserDefaults.standard.string(forKey: "SelectedLive2DModelDir")
        
        // 尝试找到保存的模型，如果找不到（比如改名了），就回退到第一个
        if let savedDir = savedDir, let found = ALL_MODELS.first(where: { $0.dir == savedDir }) {
            self.currentModel = found
        } else {
            self.currentModel = ALL_MODELS.first!
        }
    }
    
    func selectModel(_ model: ModelInfo) {
        self.currentModel = model
    }
}
