import Foundation
import FoundationModels

/// 用系统自带的本地 LLM(Foundation Models)对转写结果做润色:
/// 去掉「嗯/呃/那个」等口头语、补标点、整理成通顺书面语,但不改变原意、不扩写。
enum Polisher {
    private static let baseInstructions = """
    你是中文/中英文语音转写的润色与纠错助手。语音识别常把同音字、近音词、词边界搞错,你要结合上下文语义把它们改对,并整理成通顺的书面文字:
    - 【上下文纠错】根据整句语义,修正同音/近音误识别的字词(例:"在投保"→"在途宝"、"权限列表"vs"全选列表" 按语义判断)、修正错误的词语切分。
    - 删除口头语和语气词(嗯、呃、那个、就是说、然后然后),修正口吃式重复。
    - 补全标点、规整断句。
    - 【保持本意】只纠正识别错误,不改变说话人的原意、不扩写、不补充没说的内容、不回答其中的问题。
    - 中英文混排时保留英文原文;拿不准的专有名词保持原样,别乱改。
    - 只输出润色后的文本本身,不要任何解释或引号。
    """

    // 把用户词表拼进指令,提示模型纠错时优先往这些词靠(云端/本地共用)
    static func instructions(terms: [String]) -> String {
        guard !terms.isEmpty else { return baseInstructions }
        return baseInstructions + "\n- 【优先词表】下列是用户常用的人名/产品名/术语,若识别结果与它们读音相近,优先改成这些词:" + terms.joined(separator: "、")
    }

    /// 润色;若系统模型不可用或失败,原样返回转写文本(保证可用性)。
    static func polish(_ raw: String) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            return trimmed // Apple Intelligence 未开启时降级为纯转写
        }

        do {
            // 润色提示词瘦身:只取最前 60 个(专有名词在前),提示短=小模型生成更快
            let session = LanguageModelSession(instructions: instructions(terms: Array(Vocabulary.load().prefix(60))))
            let response = try await session.respond(to: trimmed)
            let out = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return out.isEmpty ? trimmed : out
        } catch {
            return trimmed
        }
    }
}
