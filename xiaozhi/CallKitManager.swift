// 文件: CallKitManager.swift (build 128 - Siri/CallKit 后台通话；build 138 修 intent 提前返回；build 144 修 error 6 invalidAction)
//
// Siri 唤起的系统通话：CallKit 只负责“通话壳子”（系统通话界面、挂断/静音、
// 音频会话激活），真正的连接、语音流、MCP 工具仍走 ChatViewModel / AudioService / WebSocketManager。
// 设计要点：
// - 只在 Siri 路径启用 CallKit；App 内通话不走 CallKit（不改现有流程、不动 in-app UI）。
// - 打出去的电话不需要 PushKit（没人能发推送）；但 voip 后台模式必须加
//   （build 143：无 voip 时系统以 unentitled / error 1 拒绝去电）。不改包名。
// - 每通电话一个新 UUID；系统界面挂断/静音经 CXProviderDelegate 回到 ChatViewModel。
// - build 138：startOutgoingCall 等 perform 真正到达才返回（只等 request completion
//   就返回会导致 intent 结束、App 被挂起，perform 送不到、通话界面不出现；
//   build 137 实测：快捷指令打勾完成，但始终没通话界面）。10 秒总超时兜底。
// - build 144：error 6 = invalidAction（现行枚举；旧枚举说的 maximumCallsPerCallGroupReached
//   在现行枚举里不存在，僵尸电话理论作废，重启与此无关）。头号嫌疑是 provider
//   懒创建：intent 里第一次碰 CallKitManager.shared 才创建 provider，毫秒后就发
//   transaction，系统可能还没完成 provider 注册 → action 判无效。修法：App 启动
//   时就创建 provider（xiaozhiApp.init），且创建不足 1 秒时先等满 1 秒再发 transaction。

import Foundation
import CallKit
import AVFoundation

/// 去电结果（startOutgoingCall 等 perform 到达后返回）。
enum StartCallOutcome: Sendable {
    case performed
    case rejected(String?)
    case timedOut
}

/// 抛给快捷指令 / Siri 看的中文失败原因。
struct XiaozhiCallError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// CallKit 事件回 ChatViewModel（单例对单例，weak 避免循环引用）。
protocol CallKitManagerDelegate: AnyObject {
    /// 系统接受了去电请求（CXStartCallAction 已 fulfill）：可以开始连接。
    func callKitDidPerformStartCall()
    /// 系统通话界面挂断（CXEndCallAction）：结束语音对话。
    func callKitDidEndCall()
    /// 系统通话界面静音开关。
    func callKitDidSetMuted(_ muted: Bool)
    /// 去电请求被系统拒绝：清理通话状态。
    func callKitDidFailToStart()
    /// CallKit 激活了音频会话（通话开始 / 中断恢复）：可恢复录音。
    func callKitAudioSessionDidActivate()
    /// CallKit 释放了音频会话（通话结束 / 被电话打断）：暂停音频。
    func callKitAudioSessionDidDeactivate()
}

@MainActor
final class CallKitManager: NSObject {

    static let shared = CallKitManager()

    weak var delegate: CallKitManagerDelegate?

    private let provider: CXProvider
    private let callController = CXCallController()

    /// provider 创建时间（build 144）：去电 transaction 若在 provider 刚创建
    /// （系统尚未完成注册）时发出，会被判 invalidAction（error 6）。
    private let providerCreatedAt: Date
    /// 系统当前通话快照（build 144 诊断用；只读 .calls，无需设 delegate）。
    private let callObserver = CXCallObserver()

    /// 当前 CallKit 通话的 UUID（nil = 无通话）。
    private(set) var currentCallUUID: UUID?
    /// 是否有 CallKit 通话在进行（已发起去电、尚未结束）。
    var isCallActive: Bool { currentCallUUID != nil }
    /// 系统是否已递送去电的 perform（通话真正开始）。
    private var performReceived = false
    /// 等 perform 回调的 continuation（startOutgoingCall 挂起等它；request 回调 / perform / 超时三路抢 resume，只第一个生效——全部在主线程上串行，清掉后置 nil 即可保证单次 resume）。
    private var performContinuation: CheckedContinuation<StartCallOutcome, Never>?
    /// perform 等待超时任务（10 秒总超时）。
    private var performWatchdog: Task<Void, Never>?

    /// 恢复等 perform 的 continuation（只第一个生效；其余调用点直接返回）。
    private func resumePerformContinuation(with outcome: StartCallOutcome) {
        guard let continuation = performContinuation else { return }
        performContinuation = nil
        continuation.resume(returning: outcome)
    }

    private override init() {
        // init(localizedName:) 在 iOS 14 标记废弃，但 localizedName 是只读属性，
        // 只能经由这个构造器设定（无参构造器 + 赋值编译不过），废弃警告可忽略。
        let config = CXProviderConfiguration(localizedName: "小智")
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        // 不写入系统最近通话：小智是助手不是联系人，点最近通话回拨没有意义。
        config.includesCallsInRecents = false
        self.provider = CXProvider(configuration: config)
        providerCreatedAt = Date()
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    /// 发起去电（Siri 入口调）。等到系统真正递送 perform（通话界面出现）才返回，
    /// 绝不等到 intent 提前返回、App 被挂起后 perform 送不到。
    /// 10 秒总超时：request 没回、perform 没到都算超时，失败收尾后返回，绝不无声挂起。
    func startOutgoingCall() async -> StartCallOutcome {
        guard currentCallUUID == nil else { return .rejected("已有通话在进行") }
        let uuid = UUID()
        currentCallUUID = uuid
        performReceived = false
        let handle = CXHandle(type: .generic, value: "小智")
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.isVideo = false
        // build 144：provider 创建不足 1 秒时先等满 1 秒再发 transaction，
        // 让系统有时间完成 provider 注册，否则 action 会被判 invalidAction（error 6）。
        let elapsed = Date().timeIntervalSince(providerCreatedAt)
        if elapsed < 1 {
            print("📞 CallKit provider created \(String(format: "%.2f", elapsed))s ago, waiting until 1s before request")
            try? await Task.sleep(nanoseconds: UInt64((1 - elapsed) * 1_000_000_000))
        }
        print("📞 CallKit request start: \(uuid) (provider created at \(providerCreatedAt), request at \(Date()), observed calls: \(callObserver.calls.count))")
        let outcome: StartCallOutcome = await withCheckedContinuation { continuation in
            performContinuation = continuation
            callController.request(CXTransaction(action: action)) { requestError in
                // request 回调可能不在主线程：跳回主线程再 resume（所有 resume 点都在主线程上串行）。
                Task { @MainActor in
                    if let requestError {
                        let nsError = requestError as NSError
                        let callCount = self.callObserver.calls.count
                        print("‼️ CallKit request failed: domain=\(nsError.domain) code=\(nsError.code) userInfo=\(nsError.userInfo) observedCalls=\(callCount)")
                        self.resumePerformContinuation(with: .rejected("\(requestError.localizedDescription)（系统当前通话数：\(callCount)）"))
                    } else {
                        print("📞 CallKit request accepted, waiting for perform…")
                    }
                }
            }
            // 10 秒总超时：request 没回、perform 没到都算超时，绝不让 intent 无声挂起。
            performWatchdog?.cancel()
            performWatchdog = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                print("⏰ CallKit start timed out after 10s (no perform)")
                self.resumePerformContinuation(with: .timedOut)
            }
        }
        performWatchdog?.cancel()
        performWatchdog = nil
        switch outcome {
        case .performed:
            print("📞 CallKit perform received, call started: \(uuid)")
            return .performed
        case .rejected(let message):
            print("‼️ CallKit start call rejected: \(message ?? "unknown")")
            // 只清自己的 UUID：若已被更新的去电接管（或已被僵尸清理），不要动别人的状态。
            if currentCallUUID == uuid {
                currentCallUUID = nil
                performReceived = false
                delegate?.callKitDidFailToStart()
            }
            return .rejected(message)
        case .timedOut:
            print("‼️ CallKit start call timed out: \(uuid)")
            if currentCallUUID == uuid {
                // perform 没到、界面没出现：也尝试 reportFailed，让系统侧收尾。
                reportFailed()
                delegate?.callKitDidFailToStart()
            }
            return .timedOut
        }
    }

    /// 去电开始接通（perform 回调里调）。
    func reportConnecting() {
        guard let uuid = currentCallUUID else { return }
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
    }

    /// 去电已接通（hello 到达、通话开始时调）。
    func reportConnected() {
        guard let uuid = currentCallUUID else { return }
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    /// 去电失败（连不上 / 需激活时调）：系统界面显示呼叫失败并收起。
    func reportFailed() {
        guard let uuid = currentCallUUID else { return }
        provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
        currentCallUUID = nil
        performReceived = false
    }

    /// 强制清掉当前 UUID（僵尸通话收尾用）：去电没等到 perform，或挂断的 perform
    /// 没回来时调；否则下次去电命中 guard、什么都不发生。
    func resetStaleCall() {
        guard currentCallUUID != nil else { return }
        print("⚠️ CallKit resetting stale call: \(String(describing: currentCallUUID))")
        performWatchdog?.cancel()
        performWatchdog = nil
        resumePerformContinuation(with: .timedOut)
        currentCallUUID = nil
        performReceived = false
    }

    /// 挂断（App 内挂断、xiaozhi://end 调）：发 CXEndCallAction，
    /// 系统随后调 provider(_:perform:) 回来，统一在那做收尾。
    func endCall() {
        guard let uuid = currentCallUUID else { return }
        let action = CXEndCallAction(call: uuid)
        callController.request(CXTransaction(action: action)) { _ in }
    }

    /// 静音开关（系统界面静音按钮经 delegate 回来，不直接调这个）。
    func setMuted(_ muted: Bool) {
        guard let uuid = currentCallUUID else { return }
        let action = CXSetMutedCallAction(call: uuid, muted: muted)
        callController.request(CXTransaction(action: action)) { _ in }
    }
}

// MARK: - CXProviderDelegate
extension CallKitManager: CXProviderDelegate {

    func providerDidReset(_ provider: CXProvider) {
        // Provider 被系统重置：有通话就按挂断收尾。
        performWatchdog?.cancel()
        performWatchdog = nil
        resumePerformContinuation(with: .rejected("系统重置了通话"))
        if currentCallUUID != nil {
            currentCallUUID = nil
            performReceived = false
            delegate?.callKitDidEndCall()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        action.fulfill()
        guard action.callUUID == currentCallUUID else {
            // 迟到的 perform：这通电话已超时清理过（或已被更新的去电接管），直接报失败收尾。
            print("⚠️ CallKit late perform for unknown call \(action.callUUID), failing it")
            provider.reportCall(with: action.callUUID, endedAt: Date(), reason: .failed)
            return
        }
        performReceived = true
        performWatchdog?.cancel()
        performWatchdog = nil
        resumePerformContinuation(with: .performed)
        delegate?.callKitDidPerformStartCall()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        currentCallUUID = nil
        performReceived = false
        performWatchdog?.cancel()
        performWatchdog = nil
        delegate?.callKitDidEndCall()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        action.fulfill()
        delegate?.callKitDidSetMuted(action.isMuted)
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        delegate?.callKitAudioSessionDidActivate()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        delegate?.callKitAudioSessionDidDeactivate()
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        // 系统等不到 fulfill：按挂断收尾，避免通话界面卡住。
        print("‼️ CallKit action timed out: \(type(of: action))")
        performWatchdog?.cancel()
        performWatchdog = nil
        resumePerformContinuation(with: .timedOut)
        if currentCallUUID != nil {
            currentCallUUID = nil
            performReceived = false
            delegate?.callKitDidEndCall()
        }
    }
}
