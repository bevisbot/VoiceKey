import Foundation

/// 管理本地 whisper-server 常驻进程(随 App 启动,退出时关闭)。
/// 文件位于 ~/Library/Application Support/VoiceKey/whisper/。
@MainActor
final class WhisperServer {
    nonisolated static let port = 8178
    nonisolated static let host = "127.0.0.1"

    private var process: Process?

    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceKey/whisper", isDirectory: true)
    }
    private var binURL: URL { Self.dir.appendingPathComponent("whisper-server") }
    private var modelURL: URL { Self.dir.appendingPathComponent("ggml-large-v3-turbo.bin") }

    /// 文件是否齐全(没装 Whisper 时返回 false,App 会回退到 Apple 引擎)。
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: binURL.path) &&
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    /// 启动服务(若端口已有健康实例则复用,不重复拉起)。
    func start() {
        guard isInstalled else { NSLog("VoiceKey 未安装 Whisper,跳过"); return }
        Task {
            if await self.isHealthy() { NSLog("VoiceKey whisper-server 已在运行,复用"); return }
            self.spawn()
        }
    }

    private func spawn() {
        let p = Process()
        p.executableURL = binURL
        p.arguments = [
            "-m", modelURL.path,
            "--host", Self.host,
            "--port", "\(Self.port)",
            "-l", "zh",      // 以中文为主,中英混排英文原样保留
            "-t", "6",       // 线程数
            "-fa"            // flash attention:Metal 上免费提速,不掉准确率
        ]
        let log = FileHandle(forWritingAtPath: "/tmp/voicekey-whisper.log")
            ?? { FileManager.default.createFile(atPath: "/tmp/voicekey-whisper.log", contents: nil)
                 return FileHandle(forWritingAtPath: "/tmp/voicekey-whisper.log") }()
        p.standardOutput = log
        p.standardError = log
        do {
            try p.run()
            process = p
            NSLog("VoiceKey whisper-server 已启动 pid=\(p.processIdentifier)")
        } catch {
            NSLog("VoiceKey whisper-server 启动失败:\(error.localizedDescription)")
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    /// 健康检查
    func isHealthy() async -> Bool {
        guard let url = URL(string: "http://\(Self.host):\(Self.port)/") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode != nil
        } catch {
            return false
        }
    }
}
