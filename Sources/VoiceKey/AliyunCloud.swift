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
        # 在下面单独一行粘贴你的阿里云百炼 API Key(以 sk- 开头),用于 qwen-flash 润色。
        # 这个文件只存在你本机,不会上传。粘贴后保存即可生效(无需重启)。
        # 提示:贴在这里的 key 请不要再发到任何聊天/截图里。

        """
        try? tmpl.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}

/// 给阿里云请求用的 URLSession:设"总时长硬上限",超时即整体失败(被 catch 捕获后原样返回转写文本)。
/// 注意:URLRequest.timeoutInterval 只是"空闲超时",不能限制总时长,必须用 resource 超时。
enum AliyunHTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 5   // 单次请求空闲超时
        c.timeoutIntervalForResource = 5  // 整个请求总时长上限(平时 ~1.5s;长句+抖动留足余量,免误杀)
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
}

/// 阿里云 qwen-flash 在线润色:结合上下文做同音字/词边界纠错 + 去口头语 + 补标点。
/// 仅在火山转写成功后使用;任何失败(超时/网络/解析)都原样返回转写文本,不破坏可用性。
enum CloudPolisher {
    // OpenAI 兼容端点,返回标准 choices[0].message.content
    private static let endpoint = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!

    private static let system = """
    你是中文/中英文语音转写的润色与纠错助手。语音识别常把同音字、近音词、词边界搞错,你要结合上下文语义改对,并整理成通顺书面文字:
    - 根据整句语义修正同音/近音误识别的字词、错误的词语切分。
    - 删除口头语和语气词(嗯、呃、那个、就是说),修正口吃式重复,补全标点。
    - 只纠正识别错误,不改变说话人原意、不扩写、不补充、不回答其中的问题。
    - 中英文混排保留英文原文;拿不准的专有名词保持原样。
    - 只输出润色后的文本本身,不要任何解释或引号。
    """

    static func polish(_ raw: String) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let key = AliyunConfig.loadKey() else { return trimmed }

        let body: [String: Any] = [
            "model": "qwen-flash",
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": trimmed],
            ],
            "temperature": 0.2,
        ]

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return trimmed }
        req.httpBody = payload

        do {
            let (data, resp) = try await AliyunHTTP.session.data(for: req)
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
