import Foundation

/// 用户自定义词表:常说的人名/产品名/行话。
/// - 喂给识别引擎(contextualStrings)→ 源头更容易识别对
/// - 喂给润色模型 → 上下文纠错时优先往这些词靠
/// 文件:~/Library/Application Support/VoiceKey/terms.txt(每行一个词,# 开头为注释)
enum Vocabulary {
    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceKey", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("terms.txt")
    }

    /// 读取词表;文件不存在则创建一份带示例的模板。
    static func load() -> [String] {
        let url = fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? seedTemplate.write(to: url, atomically: true, encoding: .utf8)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static let seedTemplate = """
    # VoiceKey 自定义词表:每行一个词(人名/产品名/专业术语/英文缩写等)
    # 这些词会让语音识别更容易听对,也会用于上下文纠错。
    # 用 # 开头的行是注释,会被忽略。下面是示例,按需增删:
    在途宝
    高德
    飞书
    运单
    电子围栏
    VoiceKey
    """
}
