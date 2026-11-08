// 文件: AudioService.swift (v16 - 播放/录音会话分离版)
//
// 改动说明：
// v15 的懒启动只解决了“启动就占麦克风”，但还有一个漏网路径：小智语音回复播放时，
// prepareToPlay() 也走 ensureEngineReady()，把会话配成 .playAndRecord 并激活，
// 于是纯文字聊天、只是在听小智回复时，系统麦克风指示也会亮（还可能弹麦克风权限）。
// v16 把音频会话拆成两种模式，麦克风只在真正录音时才占用：
//   - 播放模式（小智语音回复）：类别 .playback，只出声，不请求麦克风权限、不激活输入。
//   - 录音模式（按住说话 / 语音通话聆听）：类别 .playAndRecord，按住期间 / 通话进行中才激活，
//     一松手 / 通话结束就停录并释放（或降回 .playback）。
//   - 纯文字聊天、待机、进聊天页：全程不激活麦克风，系统麦克风指示绝不出现。
// 切后台不做任何保活（不要定位保活、不要静音音频保活）：后台断了就断，
// 回前台立刻自动重连（见 ChatViewModel.handleForegroundReturn）。

@preconcurrency import AVFoundation
import Foundation
import YbridOpus

struct SendablePCMBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

@MainActor
class AudioService {

    static let shared = AudioService()

    var onOpusPacket: ((Data) -> Void)?
    var onVolumeUpdate: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    private var opusEncoder: OpaquePointer?
    private var opusDecoder: OpaquePointer?

    private(set) var isRecording = false
    private(set) var isPlaying = false

    // ------------------------------------------------------------
    // 1. 格式定义
    // ------------------------------------------------------------

    private let recordingSampleRate = 16000.0
    private let recordingFrameSize = 960
    private let opusRecordingFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    private let playbackSampleRate = 24000.0
    private let opusPlaybackFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!

    private var engineProcessingFormat: AVAudioFormat?

    private var injectionEncoder: OpaquePointer?
    private var injectionBufferCache = Data()
    private var injectionConverter: AVAudioConverter?

    // ------------------------------------------------------------
    // 2. 会话模式（v16 核心）
    // ------------------------------------------------------------

    /// 音频会话模式：决定麦克风是否被占用。
    private enum SessionMode {
        case idle      // 无音频活动，会话已释放
        case playback  // 纯播放（.playback）：只出声，麦克风绝不激活
        case record    // 录音（.playAndRecord）：麦克风激活中
    }

    /// 音频引擎是否已配置（节点已连接、播放器 tap 已装）。
    /// 注意：配置好不等于会话处于激活状态；空闲时会话会被释放，下次使用时重新激活。
    private var engineConfigured = false
    /// 输入节点是否已接入混音器（只在录音模式下接，播放模式下断开，杜绝麦克风被顺带激活）。
    private var inputConnected = false
    /// 当前会话模式。
    private var sessionMode: SessionMode = .idle
    /// CallKit 通话进行中（Siri 唤起的系统通话）：会话全程保持 .playAndRecord，
    /// 不切 .playback、不释放（否则通话中途断麦、改路由）。
    var callKitCallActive = false
    /// 会话当前是否处于激活状态（setActive(true) 后为 true）。
    private var sessionActive = false
    /// 串行化会话切换：同一时间只有一个切换任务在跑，避免录音/播放切换互相打架。
    private var sessionTask: Task<Void, Never>?
    /// 会话代际：resetEngine 后递增，让在途的旧切换任务自行作废。
    private var sessionEpoch = 0

    private init() {
        // ✅ 监听系统路由变化 (一旦系统切回听筒，我们马上切回来)
        NotificationCenter.default.addObserver(self, selector: #selector(handleRouteChange), name: AVAudioSession.routeChangeNotification, object: nil)
        // 注意：这里不再立刻启动音频引擎。麦克风只在真正需要语音时才打开，
        // 纯文字聊天、待机时不占用麦克风（见 ensureSessionMode / settleSessionAfterStop）。
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // ✅ 路由守卫：系统改了路由，我们再改回来
    @objc private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        // 打印调试，看看到底是谁改了路由
        print(">>> 🎧 Route Changed: \(reason)")

        // 如果是新设备连接(如耳机)则不强制，否则强制切回扬声器
        if reason == .newDeviceAvailable { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.forceSpeaker()
        }
    }

    // ------------------------------------------------------------
    // 3. 会话模式切换（v16 核心）
    // ------------------------------------------------------------

    /// 确保会话处于指定模式（串行化：先等在途的切换任务完成，再判断是否需要切换）。
    private func ensureSessionMode(_ mode: SessionMode) async {
        if let task = sessionTask {
            await task.value
        }
        if engineConfigured && sessionMode == mode {
            // 已是目标模式：会话可能被释放过，重新激活并启动引擎即可。
            if !sessionActive {
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    sessionActive = true
                } catch {
                    print("‼️ AudioSession reactivate failed: \(error.localizedDescription)")
                    return
                }
            }
            if !engine.isRunning {
                try? engine.start()
            }
            return
        }
        let task = Task { await self.applySessionMode(mode) }
        sessionTask = task
        await task.value
        sessionTask = nil
    }

    /// 真正执行一次模式切换：停引擎 → 设类别 → 激活 → 接/断输入节点 → 启动引擎。
    /// 录音模式才会请求麦克风权限；播放模式绝不碰麦克风。
    private func applySessionMode(_ mode: SessionMode) async {
        let epoch = sessionEpoch
        let session = AVAudioSession.sharedInstance()
        do {
            if mode == .record {
                // 录音才需要麦克风权限；用户拒绝时不切换、不启动引擎。
                let hasPermission = await checkMicrophonePermission()
                guard epoch == sessionEpoch else { return } // reset 过，作废
                guard hasPermission else {
                    print("‼️ AudioService: No microphone permission.")
                    return
                }
                engine.stop()
                // ✅✅✅ 修改 1: Mode 改为 .default (最听话的模式) ✅✅✅
                // .voiceChat 和 .videoChat 都有很强的系统预设，.default 最容易被 option 覆盖
                if callKitCallActive {
                    // CallKit 通话：用 .voiceChat（系统通话回声消除、默认听筒），不加 .defaultToSpeaker
                    //（通话该走听筒，用户要免提点系统通话界面的扬声器）；App 内通话保持原来的 .default + 扬声器。
                    try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
                } else {
                    try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowAirPlay])
                }
                try session.setActive(true)
                sessionActive = true
                if !engineConfigured {
                    try setupEngineNodes(includeInput: true)
                } else if !inputConnected {
                    connectInputNode()
                }
                engine.prepare()
                try engine.start()
                sessionMode = .record
                // ✅✅✅ 修改 2: 延时强制切换 ✅✅✅
                // 引擎启动需要时间，启动瞬间系统会重置路由，所以要延时一会再设置
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.forceSpeaker()
                    print("✅ Audio Engine Started (Speaker Forced)")
                }
            } else {
                // 纯播放：类别 .playback，只有输出、没有输入，系统麦克风指示不会亮，
                // 也不请求麦克风权限——小智语音回复只是在放音，根本不需要麦克风。
                engine.stop()
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)
                sessionActive = true
                if !engineConfigured {
                    try setupEngineNodes(includeInput: false)
                } else if inputConnected {
                    disconnectInputNode()
                }
                engine.prepare()
                try engine.start()
                sessionMode = .playback
            }
        } catch {
            print("‼️ AudioSession switch to \(mode) FAILED: \(error.localizedDescription)")
        }
    }

    /// 接好引擎节点：播放器 → 混音器 → 输出，播放器上装音量监听 tap。
    /// 录音模式才把输入节点也接进来；播放模式不接输入节点。
    private func setupEngineNodes(includeInput: Bool) throws {
        let inputNode = engine.inputNode
        let mainMixer = engine.mainMixerNode
        let outputNode = engine.outputNode

        engine.attach(player)

        // 输入端（仅录音模式）
        if includeInput {
            let inputFormat = inputNode.inputFormat(forBus: 0)
            engine.connect(inputNode, to: mainMixer, format: inputFormat)
            inputNode.volume = 0.0
            inputConnected = true
        }

        // 输出端
        let hardwareSampleRate = outputNode.outputFormat(forBus: 0).sampleRate
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardwareSampleRate, channels: 1, interleaved: false) else {
            throw NSError(domain: "AudioService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot create processing format"])
        }
        self.engineProcessingFormat = monoFormat

        engine.connect(player, to: mainMixer, format: monoFormat)
        engine.connect(mainMixer, to: outputNode, format: nil)

        // 音量监听
        player.installTap(onBus: 0, bufferSize: 1024, format: monoFormat) { [weak self] (buffer, time) in
            guard let self = self else { return }
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = UInt(buffer.frameLength)
            var sum: Float = 0
            let step = 4
            for i in stride(from: 0, to: Int(frameLength), by: step) {
                let sample = channelData[i]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(frameLength / UInt(step)))
            let volume = min(max(rms * 8.0, 0.0), 1.0)
            DispatchQueue.main.async { self.onVolumeUpdate?(volume) }
        }

        engineConfigured = true
    }

    /// 播放 → 录音切换时把输入节点接进混音器（调用前引擎已停、会话已是 .playAndRecord）。
    private func connectInputNode() {
        guard !inputConnected else { return }
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        engine.connect(inputNode, to: engine.mainMixerNode, format: inputFormat)
        inputNode.volume = 0.0
        inputConnected = true
    }

    /// 录音 → 播放切换时把输入节点断开，麦克风彻底不参与播放。
    private func disconnectInputNode() {
        guard inputConnected else { return }
        engine.disconnectNodeInput(engine.inputNode, bus: 0)
        inputConnected = false
    }

    /// 录音或播放停止后整理会话：
    /// - 还在录音：保持 .playAndRecord（录音继续）。
    /// - 只剩播放：降回 .playback——麦克风立即释放，小智回复继续播。
    /// - 都停了：停引擎、释放会话，麦克风还给系统（不做后台保活，后台断了回前台重连）。
    private func settleSessionAfterStop() {
        // CallKit 通话中：会话全程保持 .playAndRecord，录音 tap 随听/说开关，
        // 但会话本身不降级、不释放（通话结束时 endCallKitAudio() 再释放）。
        if callKitCallActive { return }
        guard engineConfigured else { return }
        if isRecording { return }
        if isPlaying {
            if sessionMode == .record {
                Task { await self.ensureSessionMode(.playback) }
            }
            return
        }
        engine.stop()
        sessionMode = .idle
        sessionActive = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            print(">>> 🎤 Audio session released (idle, mic free)")
        } catch {
            print("‼️ AudioSession deactivate failed: \(error.localizedDescription)")
        }
    }

    /// CallKit 通话结束：清掉通话标记；若已无录音/播放，走正常释放路径。
    func endCallKitAudio() {
        callKitCallActive = false
        settleSessionAfterStop()
    }

    // ✅ 强力切扬声器（只在录音模式下有意义；.playback 本来就走扬声器）
    func forceSpeaker() {
        // CallKit 通话中：路由归系统通话界面管（听筒/扬声器/蓝牙），不强制切扬声器。
        guard !callKitCallActive else { return }
        // 会话未激活或不在录音模式时不碰路由，避免空闲/播放时意外重新占用麦克风
        guard engine.isRunning, sessionMode == .record else { return }
        let session = AVAudioSession.sharedInstance()

        // 1. 如果已经有耳机/蓝牙连接，不要强制切扬声器，否则用户体验很差
        let currentRoute = session.currentRoute
        for output in currentRoute.outputs {
            if output.portType == .headphones || output.portType == .bluetoothA2DP || output.portType == .bluetoothHFP || output.portType == .airPlay {
                print(">>> 🎧 正在使用外部设备 (\(output.portType.rawValue))，不强制切换扬声器")
                return
            }
        }

        // 2. 强制切换
        do {
            try session.overrideOutputAudioPort(.speaker)
            print(">>> 🔊 强制切换到扬声器成功")
        } catch {
            print("‼️ Force speaker failed: \(error)")
        }
    }

    func checkMicrophonePermission() async -> Bool {
        let status = AVAudioApplication.shared.recordPermission
        switch status {
        case .granted: return true
        case .denied: return false
        case .undetermined: return await AVAudioApplication.requestRecordPermission()
        @unknown default: return false
        }
    }

    // MARK: - 录音
    func startRecording() {
        guard !isRecording else { return }
        if engineConfigured && sessionMode == .record && engine.isRunning {
            installRecordingTap()
            return
        }
        // 切到录音模式（会弹麦克风权限），切好后再装 tap 开始录音
        Task { await self.ensureSessionMode(.record); await MainActor.run { self.installRecordingTap() } }
    }

    /// 真正装输入 tap 开始录音（调用前确保引擎已是录音模式并启动）
    private func installRecordingTap() {
        guard !isRecording else { return }
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning else { return }

        // 再次确认扬声器
        forceSpeaker()

        let inputNode = engine.inputNode
        var opusError: opus_int32 = 0
        self.opusEncoder = opus_encoder_create(opus_int32(recordingSampleRate), 1, OPUS_APPLICATION_VOIP, &opusError)
        if opusError != OPUS_OK { return }

        var pcmBufferCache = Data()
        var formatConverter: AVAudioConverter?
        let hwInputFormat = inputNode.inputFormat(forBus: 0)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwInputFormat) { (buffer, time) in
            guard let encoder = self.opusEncoder else { return }
            if formatConverter == nil { formatConverter = AVAudioConverter(from: buffer.format, to: self.opusRecordingFormat) }
            guard let converter = formatConverter else { return }

            let ratio = self.opusRecordingFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameCapacity) * ratio)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: self.opusRecordingFormat, frameCapacity: capacity) else { return }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if let pcmData = convertedBuffer.data {
                pcmBufferCache.append(pcmData)
                let frameByteSize = self.recordingFrameSize * 2
                while pcmBufferCache.count >= frameByteSize {
                    let pcmFrameData = pcmBufferCache.subdata(in: 0..<frameByteSize)
                    pcmBufferCache.removeSubrange(0..<frameByteSize)
                    var outputBuffer = [UInt8](repeating: 0, count: 1024)
                    let encodedLength = pcmFrameData.withUnsafeBytes { ptr in
                        let int16Ptr = ptr.baseAddress!.assumingMemoryBound(to: opus_int16.self)
                        return opus_encode(encoder, int16Ptr, opus_int32(self.recordingFrameSize), &outputBuffer, opus_int32(outputBuffer.count))
                    }
                    if encodedLength > 0 {
                        let packet = Data(bytes: outputBuffer, count: Int(encodedLength))
                        DispatchQueue.main.async { self.onOpusPacket?(packet) }
                    }
                }
            }
        }
        isRecording = true
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        if let encoder = self.opusEncoder {
            opus_encoder_destroy(encoder)
            self.opusEncoder = nil
        }
        // 录音停了：还在放音就降回 .playback 释放麦克风；都停了且不在通话中就释放会话
        settleSessionAfterStop()
    }

    // MARK: - 播放
    func prepareToPlay() {
        guard !isPlaying else { return }
        if callKitCallActive {
            // CallKit 通话中：会话保持 .playAndRecord（不能切 .playback，否则断麦、改路由），直接起播放器。
            startPlayback()
            return
        }
        if engineConfigured && sessionMode == .playback && engine.isRunning {
            startPlayback()
            return
        }
        // 切到纯播放模式（.playback，不碰麦克风），切好后再起播放器
        Task { await self.ensureSessionMode(.playback); await MainActor.run { self.startPlayback() } }
    }

    /// 真正创建解码器并启动播放器（调用前确保引擎已是播放模式并启动）
    private func startPlayback() {
        guard !isPlaying else { return }
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning else { return }

        var opusError: opus_int32 = 0
        opusDecoder = opus_decoder_create(opus_int32(playbackSampleRate), 1, &opusError)
        player.play()
        isPlaying = true
    }

    func play(opusPacket: Data) {
        guard isPlaying, let decoder = opusDecoder, let targetFormat = engineProcessingFormat else { return }

        let maxFrameSize = Int(playbackSampleRate * 0.120)
        var pcmOutputBuffer = [opus_int16](repeating: 0, count: maxFrameSize)

        let decodedSamples = opusPacket.withUnsafeBytes { ptr in
            let uint8Ptr = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return opus_decode(decoder, uint8Ptr, opus_int32(opusPacket.count), &pcmOutputBuffer, opus_int32(maxFrameSize), 0)
        }
        guard decodedSamples > 0 else { return }

        let frameCount = AVAudioFrameCount(decodedSamples)
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: opusPlaybackFormat, frameCapacity: frameCount) else { return }
        srcBuffer.frameLength = frameCount

        let srcPtr = srcBuffer.int16ChannelData!.pointee
        pcmOutputBuffer.withUnsafeBufferPointer { ptr in
            srcPtr.initialize(from: ptr.baseAddress!, count: Int(decodedSamples))
        }

        guard let converter = AVAudioConverter(from: opusPlaybackFormat, to: targetFormat) else { return }
        let ratio = targetFormat.sampleRate / opusPlaybackFormat.sampleRate
        let targetFrameCapacity = AVAudioFrameCount(Double(frameCount) * ratio)
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetFrameCapacity) else { return }
        let sendableSrcBuffer = SendablePCMBuffer(buffer: srcBuffer)

        var error: NSError?
        let status = converter.convert(to: dstBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return sendableSrcBuffer.buffer
        }

        if status != .error, error == nil {
            // ✅ 音量增益 3.0
            let volumeMultiplier: Float = 1.0
            if let floatChannelData = dstBuffer.floatChannelData?[0] {
                let length = Int(dstBuffer.frameLength)
                for i in 0..<length {
                    let sample = floatChannelData[i] * volumeMultiplier
                    floatChannelData[i] = max(-1.0, min(1.0, sample))
                }
            }
            player.scheduleBuffer(dstBuffer, completionHandler: nil)
        }
    }

    func stopPlaying() {
        guard isPlaying else { return }
        isPlaying = false
        player.stop()
        player.reset()
        if let decoder = opusDecoder {
            opus_decoder_destroy(decoder)
            opusDecoder = nil
        }
        // 播放停了：还在录音就保持录音模式；都停了且不在通话中就释放会话
        settleSessionAfterStop()
    }

    func resetEngine() {
        // 先把 engineConfigured 关掉，让下面 stopRecording/stopPlaying 里的 settle 变成空操作，
        // 再递增代际让在途的会话切换任务自行作废。
        engineConfigured = false
        sessionMode = .idle
        inputConnected = false
        sessionActive = false
        sessionEpoch += 1
        stopRecording()
        stopPlaying()
        engine.stop()
        engine.reset()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // (保留注入编码器相关方法...)
    func prepareInjectionEncoder() {
        if injectionEncoder == nil {
            var opusError: opus_int32 = 0
            injectionEncoder = opus_encoder_create(opus_int32(recordingSampleRate), 1, OPUS_APPLICATION_VOIP, &opusError)
            if opusError != OPUS_OK { print("Error") }
        }
        injectionBufferCache.removeAll()
        injectionConverter = nil
    }

    func destroyInjectionEncoder() {
        if let encoder = injectionEncoder {
            opus_encoder_destroy(encoder)
            injectionEncoder = nil
        }
        injectionBufferCache.removeAll()
        injectionConverter = nil
    }

    func encodeAndSendInjectionBuffer(_ inputBuffer: AVAudioPCMBuffer) {
        guard let encoder = injectionEncoder else { return }
        if inputBuffer.frameLength == 0 { return }
        if injectionConverter == nil || injectionConverter?.inputFormat != inputBuffer.format {
            injectionConverter = AVAudioConverter(from: inputBuffer.format, to: self.opusRecordingFormat)
        }
        guard let converter = injectionConverter else { return }
        let ratio = self.opusRecordingFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 128
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: self.opusRecordingFormat, frameCapacity: capacity) else { return }
        let sendableInputBuffer = SendablePCMBuffer(buffer: inputBuffer)
        var error: NSError?
        var hasFedData = false
        converter.convert(to: convertedBuffer, error: &error) { packetCount, outStatus in
            if !hasFedData {
                hasFedData = true
                outStatus.pointee = .haveData
                return sendableInputBuffer.buffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }
        if error != nil { return }
        if convertedBuffer.frameLength > 0, let pcmData = convertedBuffer.data {
            injectionBufferCache.append(pcmData)
            let frameByteSize = self.recordingFrameSize * 2
            while injectionBufferCache.count >= frameByteSize {
                let pcmFrameData = injectionBufferCache.subdata(in: 0..<frameByteSize)
                injectionBufferCache.removeSubrange(0..<frameByteSize)
                var outputBuffer = [UInt8](repeating: 0, count: 1024)
                let encodedLength = pcmFrameData.withUnsafeBytes { ptr in
                    if let int16Ptr = ptr.baseAddress?.assumingMemoryBound(to: opus_int16.self) {
                        return opus_encode(encoder, int16Ptr, opus_int32(self.recordingFrameSize), &outputBuffer, opus_int32(outputBuffer.count))
                    }
                    return opus_int32(0)
                }
                if encodedLength > 0 {
                    let packet = Data(bytes: outputBuffer, count: Int(encodedLength))
                    DispatchQueue.main.async { self.onOpusPacket?(packet) }
                }
            }
        }
    }
}

extension AVAudioPCMBuffer {
    var data: Data? {
        guard let channelData = int16ChannelData, format.commonFormat == .pcmFormatInt16 else { return nil }
        let frameLength = Int(self.frameLength)
        let channels = Int(format.channelCount)
        let byteCount = frameLength * channels * MemoryLayout<Int16>.size
        var data = Data(capacity: byteCount)
        for i in 0..<channels {
            data.append(UnsafeBufferPointer(start: channelData[i], count: frameLength))
        }
        return data
    }
}
