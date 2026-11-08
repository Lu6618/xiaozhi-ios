// 文件: XiaozhiIntents.swift (build 128 - Siri 后台通话入口；build 138 等 perform 才返回)
//
// “嘿 Siri，给小智打电话”：App Intent 在后台跑（openAppWhenRun = false），
// 不打开 App；通话由 CallKit 接管（系统通话界面 + 后台音频）。
// 注意：App Shortcuts 在 App 安装并打开过一次后才会注册到 Siri，
// 所以装好新版后要先打开一次 App，再说“嘿 Siri，给小智打电话”。
// build 138：intent 等 perform 真正到达（通话界面出现）才返回；
// 只等 request completion 就返回会导致 App 被挂起、perform 送不到
// （build 137 实测：快捷指令打勾完成，但始终没通话界面）。

import AppIntents

/// Siri 入口：给小智打电话（后台跑，不打开 App）。
struct StartXiaozhiCallIntent: AppIntent {
    static var title: LocalizedStringResource = "给小智打电话"
    static var description = IntentDescription("开始和小智语音通话，在后台进行")

    // 后台跑，不打开 App。intent 返回后 App 靠 CallKit 通话 + 音频后台模式活着。
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        // 先在主线程确保 ChatViewModel 单例已初始化（init 里碰 AudioService，
        // 必须在主线程；intent 默认跑在后台执行器上）。
        await MainActor.run {
            _ = ChatViewModel.shared
        }
        // 等 perform 真正到达（系统通话界面出现）才返回；失败时抛中文原因，
        // 快捷指令会显示出来，不要静默。App 靠 CallKit 通话 + 音频后台模式活着。
        try await ChatViewModel.shared.startCallKitCall()
        return .result()
    }
}

/// Siri 短语注册：嘿 Siri，给小智打电话 / 和小智打电话 / 呼叫小智。
/// 注意：每条短语必须恰好含一次 ${applicationName}（编译期校验），运行时替换为 App 名“小智”。
struct XiaozhiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartXiaozhiCallIntent(),
            phrases: ["给${applicationName}打电话", "和${applicationName}打电话", "呼叫${applicationName}"],
            shortTitle: "给小智打电话",
            systemImageName: "phone"
        )
    }
}
