import Foundation

/// 火山引擎 API 凭据(语音技术控制台);只从本地文件读取,App 不写入。
/// 文件:~/Library/Application Support/VoiceKey/volcano.txt(APP_ID / ACCESS_TOKEN / RESOURCE_ID)
enum VolcanoConfig {
    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceKey", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("volcano.txt")
    }

    private static func dict() -> [String: String] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [:] }
        var d: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") || !t.contains("=") { continue }
            let parts = t.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            d[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return d
    }

    static var appID: String? { dict()["APP_ID"].flatMap { $0.isEmpty ? nil : $0 } }
    static var accessToken: String? { dict()["ACCESS_TOKEN"].flatMap { $0.isEmpty ? nil : $0 } }
    static var resourceID: String { dict()["RESOURCE_ID"].flatMap { $0.isEmpty ? nil : $0 } ?? "volc.seedasr.sauc.duration" }
    static var isConfigured: Bool { appID != nil && accessToken != nil }

    static func ensureTemplate() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let tmpl = """
        # 火山引擎语音凭据(语音技术控制台 → 应用管理)
        APP_ID=
        ACCESS_TOKEN=
        RESOURCE_ID=volc.seedasr.sauc.duration
        """
        try? tmpl.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}

/// 火山引擎 豆包流式语音识别2.0 —— 实时双向流式(bigmodel_async)。
/// 录音时持续 sendPCM 推流;松手时 finish() 发结束包并拿最终文本(尾延迟 ~0.3s)。
/// 不压缩(compression=0)。无降级:失败直接抛错。
final class VolcanoStreamingSession: @unchecked Sendable {
    enum SError: Error, LocalizedError {
        case notConfigured, failed(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "未配置火山 API 凭据"
            case .failed(let m): return m
            }
        }
    }

    private let endpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
    private let q = DispatchQueue(label: "com.bevis.voicekey.volcano")
    private var ws: URLSessionWebSocketTask?
    private var session: URLSession?
    private var seq: Int32 = 1
    private var latest = ""
    private var finished = false
    private var cont: CheckedContinuation<String, Error>?

    /// 开始一次流式会话:建连 + 发配置 + 起收包循环。
    func start() throws {
        guard let appID = VolcanoConfig.appID, let token = VolcanoConfig.accessToken else {
            throw SError.notConfigured
        }
        var req = URLRequest(url: endpoint)
        req.timeoutInterval = 10
        req.setValue(appID, forHTTPHeaderField: "X-Api-App-Key")
        req.setValue(token, forHTTPHeaderField: "X-Api-Access-Key")
        req.setValue(VolcanoConfig.resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")

        let s = URLSession(configuration: .default)
        let task = s.webSocketTask(with: req)
        session = s
        ws = task
        task.resume()

        // 配置帧(JSON 不压缩 → serComp 0x10)
        let reqJSON: [String: Any] = [
            "user": ["uid": "voicekey"],
            "audio": ["format": "pcm", "rate": 16000, "bits": 16, "channel": 1],
            "request": ["model_name": "bigmodel", "enable_itn": true, "enable_punc": true],
        ]
        if let cfg = try? JSONSerialization.data(withJSONObject: reqJSON) {
            task.send(.data(Self.frame(1, 1, 0x10, 1, cfg))) { _ in }
        }
        receiveLoop()
    }

    /// 推一块实时 PCM(录音线程调用,fire-and-forget)。
    func sendPCM(_ pcm: Data) {
        q.async {
            guard let ws = self.ws, !self.finished else { return }
            self.seq += 1
            ws.send(.data(Self.frame(2, 1, 0x00, self.seq, pcm))) { _ in }
        }
    }

    /// 松手:发空的结束包(负序号),等最终结果。
    /// 兜底超时:服务端最终包久不到达(半开连接 / 静默断流)时,用已有部分结果完成,
    /// 避免 continuation 永不 resume 导致上层 busy 永久卡死。
    func finish() async throws -> String {
        try await withCheckedThrowingContinuation { c in
            q.async {
                if self.finished { c.resume(returning: self.latest); return }
                self.cont = c
                guard let ws = self.ws else { c.resume(throwing: SError.failed("连接未建立")); return }
                self.seq += 1
                ws.send(.data(Self.frame(2, 0b0011, 0x00, -self.seq, Data()))) { _ in }
                // 结果到达后由 receiveLoop → complete 触发;若 8s 内没等到最终包则兜底收尾
                self.q.asyncAfter(deadline: .now() + 8) {
                    guard !self.finished else { return }
                    if self.latest.isEmpty {
                        self.complete(.failure(SError.failed("转写超时")))
                    } else {
                        self.complete(.success(self.latest)) // 有部分结果就先用,不让用户白等
                    }
                }
            }
        }
    }

    func cancel() {
        q.async { self.cleanup(); self.ws?.cancel(with: .normalClosure, reason: nil) }
    }

    private func receiveLoop() {
        ws?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                if case let .data(d) = msg { self.q.async { self.handle(d) } }
                // re-arm 判断放回串行队列读 finished,避免与 q 上的写并发(数据竞争)
                self.q.async { if !self.finished { self.receiveLoop() } }
            case .failure(let e):
                self.q.async { self.complete(.failure(SError.failed(e.localizedDescription))) }
            }
        }
    }

    private func handle(_ d: Data) {
        let (isLast, obj) = Self.parse(d)
        if let result = obj?["result"] as? [String: Any], let t = result["text"] as? String, !t.isEmpty {
            latest = t
        }
        if isLast { complete(.success(latest)) }
    }

    private func complete(_ r: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        let c = cont; cont = nil
        switch r {
        case .success(let t): c?.resume(returning: t)
        case .failure(let e): c?.resume(throwing: e)
        }
        ws?.cancel(with: .normalClosure, reason: nil)
    }

    private func cleanup() { finished = true; cont = nil }

    // header(4) + seq(int32 BE) + size(uint32 BE) + payload
    private static func frame(_ mt: UInt8, _ fl: UInt8, _ sc: UInt8, _ seq: Int32, _ payload: Data) -> Data {
        var d = Data([0x11, (mt << 4) | fl, sc, 0x00])
        var be = seq.bigEndian; withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
        var sz = UInt32(payload.count).bigEndian; withUnsafeBytes(of: &sz) { d.append(contentsOf: $0) }
        d.append(payload)
        return d
    }

    private static func parse(_ data: Data) -> (Bool, [String: Any]?) {
        let b = [UInt8](data)
        guard b.count >= 4 else { return (false, nil) }
        let flags = b[1] & 0x0f
        var idx = 4
        if flags & 0x01 != 0 { idx += 4 }
        let isLast = (flags & 0b0010) != 0
        guard b.count >= idx + 4 else { return (isLast, nil) }
        let size = (UInt32(b[idx]) << 24) | (UInt32(b[idx+1]) << 16) | (UInt32(b[idx+2]) << 8) | UInt32(b[idx+3])
        idx += 4
        let endByte = min(b.count, idx + Int(size))
        guard idx <= endByte else { return (isLast, nil) }
        let obj = (try? JSONSerialization.jsonObject(with: Data(b[idx..<endByte]))) as? [String: Any]
        return (isLast, obj)
    }
}
