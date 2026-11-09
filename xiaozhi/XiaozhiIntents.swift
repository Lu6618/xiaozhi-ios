// 文件: XiaozhiIntents.swift
// 后台语音通话 + Siri 快捷指令（CallKit 已移除；新路线是后台音频 + Intents，不走 CallKit 系统通话界面）。
//
// 三个 intent 都在主 App Target、后台执行（openAppWhenRun = false），不打开主界面：
// - StartCallIntent：开始和小智语音通话（后台跑）
// - EndCallIntent：结束和小智的语音通话
// - CallStatusIntent：查询小智当前通话状态（只读，不触碰音频、不建连接）
//
// 约束（见 plan.md B3/B7）：
// - intent 后台唤起时绝不弹麦克风授权窗：未授权直接抛中文错，让用户先去 App 里授权。
// - 锁屏启动须提前授过麦克风 + Siri 锁屏权限。
// - 上滑杀掉 App 会立刻断通话；iOS 后台挂起是系统行为，无法绕过。
// - 没有系统通话界面、没有锁屏通话横幅：通话控制只走快捷指令 / Siri / App 内按钮。

import AppIntents

/// 抛给快捷指令 / Siri 看的中文失败原因（Siri 会直接读出 message）。
struct XiaozhiCallError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Siri / 快捷指令入口：开始和小智语音通话（后台跑，不打开 App）。
struct StartCallIntent: AppIntent {
    static var title: LocalizedStringResource = "给小智打电话"
    static var description = IntentDescription("开始和小智语音通话，在后台进行")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        try await ChatViewModel.shared.startBackgroundCall()
        return .result(dialog: "已开始和小智通话")
    }
}

/// Siri / 快捷指令入口：结束和小智的语音通话。
struct EndCallIntent: AppIntent {
    static var title: LocalizedStringResource = "挂断小智通话"
    static var description = IntentDescription("结束和小智的语音通话")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let wasInCall = await MainActor.run {
            let vm = ChatViewModel.shared
            let wasInCall = vm.backgroundCallState == .active || vm.backgroundCallState == .starting
            vm.endBackgroundCall()
            return wasInCall
        }
        return .result(dialog: wasInCall ? "已挂断和小智的通话" : "当前没有在进行的通话")
    }
}

/// Siri / 快捷指令入口：查询小智当前通话状态（只读，不触碰音频、不建连接）。
struct CallStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "小智通话状态"
    static var description = IntentDescription("查看小智当前的通话状态")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let status = await MainActor.run {
            ChatViewModel.shared.currentCallStatus()
        }
        return .result(dialog: "\(status)")
    }
}

/// App Shortcuts 注册：三组中文短语，每条必须且只能含一次 ${applicationName}（系统用它匹配 App 名“小智”）。
struct XiaoZhiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartCallIntent(),
            phrases: [
                "给${applicationName}打电话",
                "和${applicationName}打电话",
                "呼叫${applicationName}"
            ],
            shortTitle: "给小智打电话",
            systemImageName: "phone"
        )
        AppShortcut(
            intent: EndCallIntent(),
            phrases: [
                "挂断和${applicationName}的通话",
                "结束和${applicationName}的通话",
                "让${applicationName}挂断电话"
            ],
            shortTitle: "挂断小智通话",
            systemImageName: "phone.down.fill"
        )
        AppShortcut(
            intent: CallStatusIntent(),
            phrases: [
                "查看${applicationName}的通话状态",
                "${applicationName}现在在通话吗"
            ],
            shortTitle: "小智通话状态",
            systemImageName: "phone.badge.waveform"
        )
    }
}
