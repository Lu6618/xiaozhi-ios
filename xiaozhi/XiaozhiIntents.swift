// 文件: XiaozhiIntents.swift
// 后台语音通话 + Siri 快捷指令（CallKit 已移除；新路线是后台音频 + Intents，不走 CallKit 系统通话界面）。
//
// 四个 intent 都在主 App Target、后台执行（openAppWhenRun = false），不打开主界面：
// - StartCallIntent：开始和小智语音通话（后台跑）
// - EndCallIntent：结束和小智的语音通话
// - CallStatusIntent：查询小智当前通话状态（只读，不触碰音频、不建连接）
// - DiagnosticIntent：独立诊断（零依赖，见下）——先让它跑通，再修真正的通话 intent。
//
// DiagnosticIntent 的定位（2026-11-09 故障排查）：
// 三个通话 intent 在快捷指令 App 里点按只打勾、无任何反应（无报错、无结果文案），干净重装后仍一样，
// 但 unsigned-151 IPA 二进制里三个 intent + XiaoZhiShortcuts + Metadata.appintents 元数据都齐全，
// 且旧版 CallKit intent（StartXiaozhiCallIntent）在同一套签名下是能执行并弹出错误的。
// 所以先上一个零依赖的 DiagnosticIntent 做隔离测试：
// - 它跑通（弹出“小智快捷指令执行成功”）→ intent 执行机制正常，问题在通话 intent 对 ChatViewModel.shared 的冷启动依赖；
// - 它也不跑 → 问题在 intent 注册/唤起/结果送达层面，与通话逻辑无关。
// DiagnosticIntent 不调用 CallKit、不调用 ChatViewModel、不连 WebSocket、不申请麦克风、不启动音频。
//
// 约束（见 plan.md B3/B7）：
// - intent 后台唤起时绝不弹麦克风授权窗：未授权直接抛中文错，让用户先去 App 里授权。
// - 锁屏启动须提前授过麦克风 + Siri 锁屏权限。
// - 上滑杀掉 App 会立刻断通话；iOS 后台挂起是系统行为，无法绕过。
// - 没有系统通话界面、没有锁屏通话横幅：通话控制只走快捷指令 / Siri / App 内按钮。
// - 所有 intent 的异常都记日志后重新抛出，绝不静默吞掉；成功只在真正成功时报，绝不谎报。

import AppIntents
import os

/// intent 执行日志（Console.app / Xcode Devices 里按 subsystem 过滤可见）。
/// 通话类 intent 用 AppIntents，诊断 intent 用 DiagnosticIntent（任务要求）。
private let appIntentsLogger = Logger(subsystem: "com.lu6618.xiaozhi", category: "AppIntents")
private let diagnosticIntentLogger = Logger(subsystem: "com.lu6618.xiaozhi", category: "DiagnosticIntent")

/// 抛给快捷指令 / Siri 看的中文失败原因（Siri 会直接读出 message）。
struct XiaozhiCallError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 独立诊断 intent：零依赖，只验证“快捷指令能不能执行并返回结果”。
/// 不调用 CallKit，不调用 ChatViewModel / XiaoZhiCallService，不连接 WebSocket，
/// 不申请麦克风，不启动 AVAudioEngine，不要求打开小智主界面。
struct DiagnosticIntent: AppIntent {
    static var title: LocalizedStringResource = "小智快捷指令诊断"
    static var description = IntentDescription("诊断小智快捷指令是否能正常执行，不连接、不录音、不打开 App")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        diagnosticIntentLogger.info("DiagnosticIntent.perform 开始")
        do {
            // 零依赖：这里故意不碰任何主 App 对象。
            diagnosticIntentLogger.info("DiagnosticIntent.perform 执行完成")
            return .result(dialog: "小智快捷指令执行成功")
        } catch {
            diagnosticIntentLogger.error("DiagnosticIntent.perform 异常：\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

/// Siri / 快捷指令入口：开始和小智语音通话（后台跑，不打开 App）。
struct StartCallIntent: AppIntent {
    static var title: LocalizedStringResource = "给小智打电话"
    static var description = IntentDescription("开始和小智语音通话，在后台进行")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        appIntentsLogger.info("StartCallIntent.perform 开始")
        do {
            // 冷启动预热：先在 MainActor 上初始化 ChatViewModel 单例。
            // 旧版 CallKit intent（StartXiaozhiCallIntent）就是先这样预热再干活的，它能正常执行并弹出错误；
            // 新版之前是直接从 perform() 跨 actor 访问单例，主 App 未启动时唤不起来，只打勾、无反应。
            // 预热本身不连网、不录音、不弹授权。
            await MainActor.run { _ = ChatViewModel.shared }
            try await ChatViewModel.shared.startBackgroundCall()
            // 诚实成功：只有真正进入 active 才报“已开始”；否则抛可见错误，绝不谎报成功。
            let state = await MainActor.run { ChatViewModel.shared.backgroundCallState }
            guard state == .active else {
                throw XiaozhiCallError(message: "通话未能开始，请打开小智 App 查看状态")
            }
            appIntentsLogger.info("StartCallIntent.perform 执行完成，通话已开始")
            return .result(dialog: "已开始和小智通话")
        } catch {
            appIntentsLogger.error("StartCallIntent.perform 异常：\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

/// Siri / 快捷指令入口：结束和小智的语音通话。
struct EndCallIntent: AppIntent {
    static var title: LocalizedStringResource = "挂断小智通话"
    static var description = IntentDescription("结束和小智的语音通话")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        appIntentsLogger.info("EndCallIntent.perform 开始")
        do {
            let wasInCall = await MainActor.run {
                let vm = ChatViewModel.shared
                let wasInCall = vm.backgroundCallState == .active || vm.backgroundCallState == .starting
                vm.endBackgroundCall()
                return wasInCall
            }
            appIntentsLogger.info("EndCallIntent.perform 执行完成")
            return .result(dialog: wasInCall ? "已挂断和小智的通话" : "当前没有在进行的通话")
        } catch {
            appIntentsLogger.error("EndCallIntent.perform 异常：\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

/// Siri / 快捷指令入口：查询小智当前通话状态（只读，不触碰音频、不建连接）。
struct CallStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "小智通话状态"
    static var description = IntentDescription("查看小智当前的通话状态")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        appIntentsLogger.info("CallStatusIntent.perform 开始")
        do {
            let status = await MainActor.run {
                ChatViewModel.shared.currentCallStatus()
            }
            appIntentsLogger.info("CallStatusIntent.perform 执行完成")
            return .result(dialog: "\(status)")
        } catch {
            appIntentsLogger.error("CallStatusIntent.perform 异常：\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

/// App Shortcuts 注册：中文短语，每条必须且只能含一次 ${applicationName}（系统用它匹配 App 名“小智”）。
/// 名称与 Intent 类型一一对应：给小智打电话→StartCallIntent，挂断小智通话→EndCallIntent，
/// 小智通话状态→CallStatusIntent，小智诊断→DiagnosticIntent。不要只改显示名。
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
        AppShortcut(
            intent: DiagnosticIntent(),
            phrases: [
                "诊断${applicationName}快捷指令"
            ],
            shortTitle: "小智诊断",
            systemImageName: "stethoscope"
        )
    }
}
