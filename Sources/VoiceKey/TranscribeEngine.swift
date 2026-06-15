import Foundation

/// 转写引擎抽象:Apple 系统引擎 与 Whisper 本地服务都实现它,可随时切换。
protocol TranscribeEngine: Sendable {
    func transcribe(fileURL: URL) async throws -> String
}
