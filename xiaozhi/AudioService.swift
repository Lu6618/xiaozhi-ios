// 文件: AudioService.swift (v15 - 麦克风按需占用版)
//
// 改动说明：
// 旧版在 init 里就立刻 setupAndStartEngine（setCategory(.playAndRecord) +
// setActive(true) + engine.start()），导致 App 一启动就占用麦克风，
// 纯文字聊天、待机时麦克风指示灯也一直亮着。
// 新版改为懒启动：只有真正需要语音（按住说话、免提聆听、播放 AI 回复）时
// 才激活音频会话；录音/播放都停了且空闲时立刻 setActive(false) 释放麦克风。

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

    /// 音频引擎是否已配置（节点已连接、session 类别已设置）。
    /// 注意：配置好不等于会话处于激活状态；空闲时会话会被释放，下次使用时重新激活。
    private var engineConfigured = false
    private var setupTask: Task<Void, Never>?
    
    private init() {
        // ✅ 监听系统路由变化 (一旦系统切回听筒，我们马上切回来)
        NotificationCenter.default.addObserver(self, selector: #selector(handleRouteChange), name: AVAudioSession.routeChangeNotification, object: nil)
        // 注意：这里不再立刻启动音频引擎。麦克风只在真正需要语音时才打开，
        // 纯文字聊天、待机时不占用麦克风（见 ensureEngineReady / releaseAudioSessionIfIdle）。
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
    
    /// 确保音频引擎可用：首次使用时做完整配置（会弹麦克风权限），
    /// 之后空闲释放过会话的，只需重新激活会话并启动引擎。
    private func ensureEngineReady() async {
        if engineConfigured {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                print("‼️ AudioSession reactivate failed: \(error.localizedDescription)")
                return
            }
            if !engine.isRunning {
                try? engine.start()
            }
            return
        }
        if let task = setupTask {
            await task.value
            return
        }
        let task = Task { await self.performEngineSetup() }
        setupTask = task
        await task.value
        setupTask = nil
    }
    
    /// 首次完整配置：设 session 类别、激活、连节点、装播放音量 tap、启动引擎。
    /// 只有真正需要语音（录音/播放）时才会被调用，不在 App 启动时跑。
    private func performEngineSetup() async {
        guard !engine.isRunning else {
            engineConfigured = true
            return
        }
        
        do {
            let audioSession = AVAudioSession.sharedInstance()
            let hasPermission = await checkMicrophonePermission()
            guard hasPermission else {
                print("‼️ AudioService: No microphone permission.")
                return
            }
            
            // ✅✅✅ 修改 1: Mode 改为 .default (最听话的模式) ✅✅✅
            // .voiceChat 和 .videoChat 都有很强的系统预设，.default 最容易被 option 覆盖
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowAirPlay])
            
            try audioSession.setActive(true)
            
            let inputNode = engine.inputNode
            let mainMixer = engine.mainMixerNode
            let outputNode = engine.outputNode
            
            engine.attach(player)
            
            // 输入端
            let inputFormat = inputNode.inputFormat(forBus: 0)
            engine.connect(inputNode, to: mainMixer, format: inputFormat)
            inputNode.volume = 0.0
            
            // 输出端
            let hardwareSampleRate = outputNode.outputFormat(forBus: 0).sampleRate
            guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardwareSampleRate, channels: 1, interleaved: false) else { return }
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
            
            engine.prepare()
            try engine.start()
            engineConfigured = true
            
            // ✅✅✅ 修改 2: 延时强制切换 ✅✅✅
            // 引擎启动需要时间，启动瞬间系统会重置路由，所以要延时一会再设置
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.forceSpeaker()
                print("✅ Audio Engine Started (Speaker Forced)")
            }
            
        } catch {
            print("‼️ Engine Start FAILED: \(error.localizedDescription)")
        }
    }
    
    /// 空闲时释放音频会话：录音和播放都停了，就把麦克风还给系统。
    /// 纯文字聊天、待机时调用此方法后，麦克风指示灯熄灭，不再占用。
    private func releaseAudioSessionIfIdle() {
        guard engineConfigured, !isRecording, !isPlaying else { return }
        engine.stop()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            print(">>> 🎤 Audio session released (idle, mic free)")
        } catch {
            print("‼️ AudioSession deactivate failed: \(error.localizedDescription)")
        }
    }
    
    // ✅ 强力切扬声器
    func forceSpeaker() {
        // 会话未激活时不碰路由，避免空闲时意外重新占用麦克风
        guard engine.isRunning else { return }
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
        if engineConfigured {
            installRecordingTap()
            return
        }
        // 引擎还没配好：先懒配置（会弹麦克风权限），配好后再装 tap 开始录音
        Task { await self.ensureEngineReady(); await MainActor.run { self.installRecordingTap() } }
    }

    /// 真正装输入 tap 开始录音（调用前确保引擎已配置并启动）
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
        // 录音停了且没在放音：释放会话，麦克风还给系统
        releaseAudioSessionIfIdle()
    }
    
    // MARK: - 播放
    func prepareToPlay() {
        guard !isPlaying else { return }
        if engineConfigured {
            startPlayback()
            return
        }
        // 引擎还没配好：先懒配置，配好后再起播放器
        Task { await self.ensureEngineReady(); await MainActor.run { self.startPlayback() } }
    }

    /// 真正创建解码器并启动播放器（调用前确保引擎已配置并启动）
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
        // 播放停了且没在录音：释放会话，麦克风还给系统
        releaseAudioSessionIfIdle()
    }
    
    func resetEngine() {
        stopRecording()
        stopPlaying()
        engine.stop()
        engine.reset()
        // reset 会清掉节点连接，下次使用要重新完整配置
        engineConfigured = false
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
