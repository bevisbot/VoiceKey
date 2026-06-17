import AVFoundation

/// 录音:实时把麦克风音频重采样为 16k 单声道 16bit PCM,边录边通过 onPCM 吐出(供流式上传);
/// 同时通过 onLevel 吐音量驱动悬浮波形。不落盘(实时流式,无需文件)。
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 16_000, channels: 1, interleaved: true)!

    /// 实时 16k 单声道 PCM 数据块(录音时持续回调)
    var onPCM: (@Sendable (Data) -> Void)?
    /// 实时音量(0~1),驱动悬浮波形
    var onLevel: (@Sendable (Float) -> Void)?

    func start() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: target)

        input.installTap(onBus: 0, bufferSize: 3200, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)  // 先摘 tap,确保不再有新的回调
        engine.stop()
        onPCM = nil   // 摘 tap 后再清回调,避免与录音线程并发读写闭包
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        reportLevel(buffer)
        guard let onPCM, let converter else { return }  // 一次性取出回调,缩小竞争窗口

        let ratio = target.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }

        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard err == nil, out.frameLength > 0,
              let ch = out.int16ChannelData else { return }
        let bytes = Int(out.frameLength) * 2  // 16bit = 2 bytes/sample, mono
        let data = Data(bytes: ch[0], count: bytes)
        onPCM(data)
    }

    // RMS 音量 → 0~1(从原始 float 缓冲算)
    private func reportLevel(_ buffer: AVAudioPCMBuffer) {
        guard let onLevel, let ch = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength); guard n > 0 else { return }
        let p = ch[0]; var sum: Float = 0
        for i in 0..<n { let s = p[i]; sum += s * s }
        let rms = (sum / Float(n)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        let level = max(0, min(1, (db + 50) / 50))
        DispatchQueue.main.async { onLevel(level) }
    }
}
