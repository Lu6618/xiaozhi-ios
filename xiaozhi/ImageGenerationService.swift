import Foundation

enum ImageGenerationError: LocalizedError {
    case missingConfiguration
    case invalidResponse
    var errorDescription: String? {
        switch self {
        case .missingConfiguration: return "请先配置生图接口、模型和 API Key。"
        case .invalidResponse: return "生图接口返回格式无法解析。"
        }
    }
}

final class ImageGenerationService {
    static let shared = ImageGenerationService()
    private init() {}

    func generate(prompt: String, endpoint: String, model: String, apiKey: String) async throws -> Data {
        guard let url = URL(string: endpoint), !model.isEmpty, !apiKey.isEmpty else {
            throw ImageGenerationError.missingConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer (apiKey)", forHTTPHeaderField: "Authorization")
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
