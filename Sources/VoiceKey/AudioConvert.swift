import Foundation

/// 用系统 afconvert 把任意录音转成 16k 单声道 16bit WAV(Whisper / 阿里云都要这个格式)。
enum AudioConvert {
    enum ConvertError: Error { case failed }

    static func to16kMonoWav(_ input: URL) throws -> URL {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("vk-16k-\(UUID().uuidString).wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", input.path, out.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              FileManager.default.fileExists(atPath: out.path) else {
            throw ConvertError.failed
        }
        return out
    }
}
