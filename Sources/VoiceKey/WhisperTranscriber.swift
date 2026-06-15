import Foundation

/// Whisper 本地服务转写器:把录音转成 16k 单声道 WAV,POST 给 whisper-server。
/// 中英混排明显优于系统引擎。
struct WhisperTranscriber: TranscribeEngine {
    enum WhisperError: Error, LocalizedError {
        case notReady
        case badResponse

        var errorDescription: String? {
            switch self {
            case .notReady: return "Whisper 引擎未就绪(正在启动,请稍候重试)"
            case .badResponse: return "Whisper 返回异常"
            }
        }
    }

    private var inferenceURL: URL {
        URL(string: "http://\(WhisperServer.host):\(WhisperServer.port)/inference")!
    }

    func transcribe(fileURL: URL) async throws -> String {
        let wav = try AudioConvert.to16kMonoWav(fileURL)
        defer { try? FileManager.default.removeItem(at: wav) }

        var req = URLRequest(url: inferenceURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 120

        let boundary = "VoiceKeyBoundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = try multipartBody(wavURL: wav, boundary: boundary)

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw WhisperError.notReady // 连不上 = 服务还没起来
        }
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw WhisperError.notReady }

        // 解析 {"text": "..."}
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else {
            throw WhisperError.badResponse
        }
        return cleanup(text)
    }

    // 用 afconvert 转成 whisper 需要的 16k 单声道 16bit WAV
    private func multipartBody(wavURL: URL, boundary: String) throws -> Data {
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }

        let wavData = try Data(contentsOf: wavURL)
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        append("\r\n")

        // 中文引导词 + 用户词表:把 Whisper 往正确的简体中文写法 / 专有名词上拽,减少同音字误判
        // 注意:Whisper 引导词有 token 上限,词太多会稀释,这里只取靠前的若干个(专有名词优先)
        var prompt = "以下是简体中文普通话的转写,可能夹杂少量英文专业术语,请使用规范的简体中文。"
        let terms = Array(Vocabulary.load().prefix(40))
        if !terms.isEmpty { prompt += "常见词汇:" + terms.joined(separator: "、") + "。" }

        let params: [(String, String)] = [
            ("language", "zh"),
            ("temperature", "0"),
            ("beam_size", "3"),       // 波束搜索:速度↔准确折中(5 最准最慢,1 最快)
            ("prompt", prompt),
            ("response_format", "json"),
        ]
        for (k, v) in params {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(k)\"\r\n\r\n")
            append("\(v)\r\n")
        }
        append("--\(boundary)--\r\n")
        return body
    }

    // 清理 whisper 常见噪声标记
    private func cleanup(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for noise in ["[BLANK_AUDIO]", "(silence)", "[MUSIC]", "[音乐]", "(无声)"] {
            t = t.replacingOccurrences(of: noise, with: "")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
