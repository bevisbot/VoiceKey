import Foundation

/// 阿里云 API Key 配置:只从本地文件读取,App 不写入/不搬运密钥。
/// 文件:~/Library/Application Support/VoiceKey/aliyun.txt(粘贴 sk- 开头的 key,单独一行)
enum AliyunConfig {
    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceKey", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("aliyun.txt")
    }

    /// 读取 key(第一行非注释、非空内容)。没有则返回 nil。
    static func loadKey() -> String? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            return t
        }
        return nil
    }

    static var isConfigured: Bool { loadKey() != nil }

    /// 确保文件存在(带说明模板,供用户粘贴 key)。
    static func ensureTemplate() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let tmpl = """
        # 在下面单独一行粘贴你的阿里云百炼 API Key(以 sk- 开头)。
        # 这个文件只存在你本机,不会上传。粘贴后保存即可,菜单里打开「在线优先」。
        # 提示:贴在这里的 key 请不要再发到任何聊天/截图里。

        """
        try? tmpl.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}

/// 阿里云百炼 Qwen3-ASR-Flash 在线转写(中英混排 / 上下文纠错更强)。
/// 同步多模态接口,音频以 base64 内联,不上传到第三方公网。
struct AliyunCloudTranscriber: TranscribeEngine {
    enum CloudError: Error, LocalizedError {
        case notConfigured, http(Int), badResponse
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "未配置阿里云 API Key"
            case .http(let c): return "阿里云接口返回 \(c)"
            case .badResponse: return "阿里云返回解析失败"
            }
        }
    }

    // 北京区端点(控制台显示「华北2 北京」)
    private let endpoint = URL(string: "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")!

    func transcribe(fileURL: URL) async throws -> String {
        guard let key = AliyunConfig.loadKey() else { throw CloudError.notConfigured }

        let wav = try AudioConvert.to16kMonoWav(fileURL)
        defer { try? FileManager.default.removeItem(at: wav) }
        let b64 = try Data(contentsOf: wav).base64EncodedString()

        // 词表作为上下文偏置(放进 system),与本地一致
        let terms = Array(Vocabulary.load().prefix(100))
        let context = terms.isEmpty ? "" : "常见词汇:" + terms.joined(separator: "、")

        let body: [String: Any] = [
            "model": "qwen3-asr-flash",
            "input": [
                "messages": [
                    ["role": "system", "content": [["text": context]]],
                    ["role": "user", "content": [["audio": "data:audio/wav;base64,\(b64)"]]],
                ]
            ],
            "parameters": ["asr_options": ["language": "zh", "enable_itn": true]],
        ]

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw CloudError.http(code) }

        // output.choices[0].message.content[0].text
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = obj["output"] as? [String: Any],
              let choices = output["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw CloudError.badResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 阿里云 qwen-plus 在线润色:比本地 3B 更强的上下文/同音字纠错。
/// 仅在"在线转写成功"后使用;任何失败都原样返回转写文本(不破坏可用性)。
enum CloudPolisher {
    // OpenAI 兼容端点,返回标准 choices[0].message.content
    private static let endpoint = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!

    static func polish(_ raw: String) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let key = AliyunConfig.loadKey() else { return trimmed }

        let system = Polisher.instructions(terms: Array(Vocabulary.load().prefix(120)))
        let body: [String: Any] = [
            "model": "qwen-plus",
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": trimmed],
            ],
            "temperature": 0.2,
        ]

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return trimmed }
        req.httpBody = payload

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                return trimmed // 失败 → 用未润色的转写,保证可用
            }
            let out = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return out.isEmpty ? trimmed : out
        } catch {
            return trimmed
        }
    }
}
