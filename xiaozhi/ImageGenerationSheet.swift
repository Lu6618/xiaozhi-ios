import SwiftUI

struct ImageGenerationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var endpoint = UserDefaults.standard.string(forKey: "ImageAIEndpoint") ?? "https://api.openai.com/v1/images/generations"
    @State private var model = UserDefaults.standard.string(forKey: "ImageAIModel") ?? "gpt-image-1"
    @State private var apiKey = KeychainHelper.load(key: "com.xiaozhi.image.apiKey") ?? ""
    @State private var image: UIImage?
    @State private var isGenerating = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("生成描述") { TextEditor(text: $prompt).frame(minHeight: 100) }
                Section("模型配置") {
                    TextField("接口地址", text: $endpoint).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("模型名称", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("API Key", text: $apiKey)
                }
                if let image { Section("结果") { Image(uiImage: image).resizable().scaledToFit() } }
                if let errorText { Text(errorText).foregroundStyle(.red) }
                Button { generate() } label: { HStack { Spacer(); if isGenerating { ProgressView() } else { Text("生成图片") }; Spacer() } }.disabled(isGenerating || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .navigationTitle("AI 生图")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }

    private func generate() {
        isGenerating = true; errorText = nil
        UserDefaults.standard.set(endpoint, forKey: "ImageAIEndpoint")
        UserDefaults.standard.set(model, forKey: "ImageAIModel")
        _ = KeychainHelper.save(key: "com.xiaozhi.image.apiKey", string: apiKey)
        Task {
            do { let data = try await ImageGenerationService.shared.generate(prompt: prompt, endpoint: endpoint, model: model, apiKey: apiKey); await MainActor.run { image = UIImage(data: data); isGenerating = false } }
            catch { await MainActor.run { errorText = error.localizedDescription; isGenerating = false } }
        }
    }
}
