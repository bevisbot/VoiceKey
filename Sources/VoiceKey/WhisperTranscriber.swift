import Foundation

/// Whisper 本地服务转写器:把录音转成 16k 单声道 WAV,POST 给 whisper-server。
/// 中英混排明显优于系统引擎。
struct WhisperTranscriber: TranscribeEngine {
    enum WhisperError: Error, LocalizedError {
        case notReady
        case convertFailed
        case badResponse

        var errorDescription: String? {
            switch self {
            case .notReady: return "Whisper 引擎未就绪(正在启动,请稍候重试)"
            case .convertFailed: return "音频转换失败"
            case .badResponse: return "Whisper 返回异常"
            }
        }
    }

    private var inferenceURL: URL {
        URL(string: "http://\(WhisperServer.host):\(WhisperServer.port)/inference")!
    }

    func transcribe(fileURL: URL) async throws -> String {
        let wav = try convertTo16kWav(fileURL)
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
    private func convertTo16kWav(_ input: URL) throws -> URL {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("vk-whisper-\(UUID().uuidString).wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", input.path, out.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              FileManager.default.fileExists(atPath: out.path) else {
            throw WhisperError.convertFailed
        }
        return out
    }

    private func multipartBody(wavURL: URL, boundary: String) throws -> Data {
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }

        let wavData = try Data(contentsOf: wavURL)
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        append("\r\n")

        // 中文为主,中英混排英文原样保留
        for (k, v) in ["temperature": "0", "language": "zh", "response_format": "json"] {
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
