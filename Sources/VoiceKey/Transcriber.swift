import Foundation
import AVFoundation
import Speech

/// 语音转写:使用 macOS 26 内置的 SpeechAnalyzer / SpeechTranscriber(本地、离线)。
/// 中文用 zh-CN,可处理中英混排(英文原样保留)。
actor Transcriber: TranscribeEngine {
    enum TranscribeError: Error, LocalizedError {
        case unavailable
        case localeUnsupported(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "本设备不支持 SpeechTranscriber(需 macOS 26 + Apple 芯片)"
            case .localeUnsupported(let l): return "不支持的语言:\(l)"
            }
        }
    }

    private let localeID: String

    init(localeID: String = "zh-CN") {
        self.localeID = localeID
    }

    /// 预热:启动时后台确保 zh-CN 模型已装好,避免首次降级时冷下载卡住。
    func prepare() async {
        guard SpeechTranscriber.isAvailable else { return }
        let locale = Locale(identifier: localeID)
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return }
        let t = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        try? await ensureModelInstalled(for: t, locale: supported)
    }

    /// 转写一个录好的音频文件,返回纯文本。
    func transcribe(fileURL: URL) async throws -> String {
        guard SpeechTranscriber.isAvailable else { throw TranscribeError.unavailable }

        let locale = Locale(identifier: localeID)
        // 找到与目标语言等价的、受支持的 locale
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscribeError.localeUnsupported(localeID)
        }

        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )

        try await ensureModelInstalled(for: transcriber, locale: supported)

        let audioFile = try AVAudioFile(forReading: fileURL)

        // 自定义词表 → 让识别在源头更容易听对人名/产品名/行话
        let context = AnalysisContext()
        let terms = Vocabulary.load()
        if !terms.isEmpty {
            context.contextualStrings = [.general: terms]
        }

        // 边分析边收集结果文本
        let collector = Task { () -> String in
            var full = AttributedString()
            for try await result in transcriber.results {
                full.append(result.text)
            }
            return String(full.characters)
        }

        let analyzer = try await SpeechAnalyzer(
            inputAudioFile: audioFile,
            modules: [transcriber],
            options: nil,
            analysisContext: context,
            finishAfterFile: true
        )
        _ = analyzer // 持有,直到分析结束

        let text = try await collector.value
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 确保该语言的本地模型已下载安装(首次使用会触发系统下载)。
    private func ensureModelInstalled(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let installed = await SpeechTranscriber.installedLocales
        let already = installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        if already { return }

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }
}
