import Foundation

enum ImageGenerationError: LocalizedError {
    case missingConfiguration
    case invalidResponse
    var errorDescription: String? {
        switch self {
        case .missingConfiguration: return "请先在服务设置里配置视觉接口地址、模型和 API Key。"
        case .invalidResponse: return "生图接口返回格式无法解析。"
        }
    }
}

/// 生图服务：复用服务设置里的同一套“地址 + Key + 模型”配置（不再另起一套）。
/// 生图走 OpenAI 兼容的 /images/generations 接口；意图识别走配置的大模型。
final class ImageGenerationService {
    static let shared = ImageGenerationService()
    private init() {}

    // MARK: - 意图识别

    /// 快速本地门控：只有文本可能与生图有关时才去问模型，避免每次对话都多一次模型调用。
    /// 这里只是“要不要问模型”的开关，最终是不是生图、画什么，由模型说了算。
    static func mightBeImageRequest(_ text: String) -> Bool {
        let keywords = ["画", "生图", "生成图片", "生成一张", "生成一幅", "画一张", "画一幅",
                        "帮我画", "给我画", "画个", "画只", "画个", "图片", "绘图", "作画",
                        "生成图", "来张图", "出一张", "做一张图", "做个图", "设计一张"]
        return keywords.contains { text.contains($0) }
    }

    /// 让配置的大模型判断用户是不是想生图；是则返回提炼后的图片描述，否则返回 nil。
    /// 模型只返回严格 JSON：{"is_image": true/false, "prompt": "..."}。
    func detectImagePrompt(for text: String) async -> String? {
        let system = """
        你是一个意图分类器。判断用户是否想生成一张图片。
        只返回严格 JSON，不要其他文字，格式如下：
        {"is_image": true, "prompt": "图片的详细描述，用中文，保留用户原意"}
        如果不是生成图片的请求，返回：
        {"is_image": false, "prompt": ""}
        """
        do {
            let reply = try await VisionService.completeText(system: system, user: text, maxTokens: 200)
            guard let start = reply.firstIndex(of: "{"),
                  let end = reply.lastIndex(of: "}"),
                  start <= end else { return nil }
            let jsonText = String(reply[start...end])
            guard let data = jsonText.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let isImage = json["is_image"] as? Bool, isImage else { return nil }
            let prompt = (json["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return prompt.isEmpty ? text : prompt
        } catch {
            print(">>> 🎨 [ImageIntent] 模型判断失败: \(error)")
            return nil
        }
    }

    // MARK: - 生图

    /// 用服务设置里的同一套配置生图：基础地址 + Key + 模型。
    /// 接口为 <base>/images/generations（OpenAI 兼容）。
    func generateWithVisionConfig(prompt: String) async throws -> Data {
        let base = AppConfig.visionAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = AppConfig.visionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = AppConfig.visionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !apiKey.isEmpty, !model.isEmpty else {
            throw ImageGenerationError.missingConfiguration
        }
        guard let endpoint = AppConfig.visionURL(path: "/images/generations", base: base) else {
            throw ImageGenerationError.missingConfiguration
        }
        return try await generate(prompt: prompt, endpoint: endpoint, model: model, apiKey: apiKey)
    }

    /// 底层生图调用：POST <endpoint>，OpenAI images 格式，优先取 b64_json，其次取 url 下载。
    func generate(prompt: String, endpoint: String, model: String, apiKey: String) async throws -> Data {
        guard let url = URL(string: endpoint), !model.isEmpty, !apiKey.isEmpty else {
            throw ImageGenerationError.missingConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "prompt": prompt,
            "size": "1024x1024",
            "response_format": "b64_json"
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NetworkServiceError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]],
              let first = items.first else { throw ImageGenerationError.invalidResponse }
        if let b64 = first["b64_json"] as? String, let image = Data(base64Encoded: b64) { return image }
        if let urlString = first["url"] as? String, let imageURL = URL(string: urlString) {
            let (image, _) = try await URLSession.shared.data(from: imageURL)
            return image
        }
        throw ImageGenerationError.invalidResponse
    }
}
