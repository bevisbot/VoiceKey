import AVFoundation

/// 录音:把麦克风采集到的音频写入临时文件,供 SpeechTranscriber 读取。
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private(set) var fileURL: URL?

    /// 实时音量回调(0~1),用于驱动悬浮控件的声波动画。
    var onLevel: (@Sendable (Float) -> Void)?

    /// 开始录音(需先获得麦克风权限)。
    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicekey-\(UUID().uuidString).caf")
        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        self.file = audioFile
        self.fileURL = url

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            try? self?.file?.write(from: buffer)
            self?.reportLevel(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    // 计算这一块缓冲的 RMS 音量,归一化后回调到主线程
    private func reportLevel(_ buffer: AVAudioPCMBuffer) {
        guard let onLevel, let ch = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let ptr = ch[0]
        var sum: Float = 0
        for i in 0..<n { let s = ptr[i]; sum += s * s }
        let rms = (sum / Float(n)).squareRoot()
        // -50dB ~ 0dB 映射到 0~1
        let db = 20 * log10(max(rms, 1e-7))
        let level = max(0, min(1, (db + 50) / 50))
        DispatchQueue.main.async { onLevel(level) }
    }

    /// 停止录音,返回写好的音频文件 URL。
    @discardableResult
    func stop() -> URL? {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil // 关闭文件
        return fileURL
    }
}
