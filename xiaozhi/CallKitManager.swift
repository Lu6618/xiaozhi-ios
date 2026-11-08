// 文件: CallKitManager.swift (build 128 - Siri/CallKit 后台通话)
//
// Siri 唤起的系统通话：CallKit 只负责“通话壳子”（系统通话界面、挂断/静音、
// 音频会话激活），真正的连接、语音流、MCP 工具仍走 ChatViewModel / AudioService / WebSocketManager。
// 设计要点：
// - 只在 Siri 路径启用 CallKit；App 内通话不走 CallKit（不改现有流程、不动 in-app UI）。
// - 打出去的电话不需要 PushKit，所以不加 voip 后台模式、不改包名。
// - 每通电话一个新 UUID；系统界面挂断/静音经 CXProviderDelegate 回到 ChatViewModel。

import Foundation
import CallKit
import AVFoundation

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

    /// 当前 CallKit 通话的 UUID（nil = 无通话）。
    private(set) var currentCallUUID: UUID?
    /// 是否有 CallKit 通话在进行（已发起去电、尚未结束）。
    var isCallActive: Bool { currentCallUUID != nil }

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
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    /// 发起去电（Siri 入口调）。await 到“系统接受了去电请求”才返回，
    /// 避免 intent 一结束系统就把后台 App 挂起；真正的 perform 回调随后到。
    func startOutgoingCall() async {
        guard currentCallUUID == nil else { return }
        let uuid = UUID()
        currentCallUUID = uuid
        let handle = CXHandle(type: .generic, value: "小智")
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.isVideo = false
        let error: Error? = await withCheckedContinuation { continuation in
            callController.request(CXTransaction(action: action)) { requestError in
                continuation.resume(returning: requestError)
            }
        }
        if error != nil {
            print("‼️ CallKit start call failed: \(error!.localizedDescription)")
            currentCallUUID = nil
            delegate?.callKitDidFailToStart()
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
        if currentCallUUID != nil {
            currentCallUUID = nil
            delegate?.callKitDidEndCall()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        action.fulfill()
        delegate?.callKitDidPerformStartCall()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        currentCallUUID = nil
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
        if currentCallUUID != nil {
            currentCallUUID = nil
            delegate?.callKitDidEndCall()
        }
    }
}
