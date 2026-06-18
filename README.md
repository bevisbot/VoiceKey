# VoiceKey — 中文 / 中英混杂语音输入工具(Typeless 替代)

在**任意 App 的任意输入框**,按一下快捷键说话,实时转写 → AI 润色 → 自动插入到光标处。
专为**中文 / 中英混杂**优化,延迟低(松手到出字约 1~1.5 秒)。

## 架构(单一链路,无降级)

```
按一下右 Command → 边录边推流火山(实时识别)→ 再按一下结束
   → 松手 ~0.3s 出转写 → qwen-plus 润色(~1s)→ 自动 ⌘V 粘贴
```

| 环节 | 用什么 | 说明 |
|---|---|---|
| 转写 | 火山引擎 **豆包流式语音识别2.0**(Seed) | WebSocket 双向流式 `bigmodel_async`,边说边传,松手即得(~0.3s) |
| 润色 | 阿里云 **qwen-plus** | 去口头语、补标点、按上下文纠正同音字/词边界;大模型自带词库,无需自定义词表 |
| 录音 | AVAudioEngine | 实时重采样 16k 单声道 PCM 推流 |
| 插入 | 剪贴板 + 合成 ⌘V | 粘贴后还原剪贴板,对所有 App 通用 |
| 快捷键 | CGEventTap | 点按右 Command 切换(只识别单独点按,不误触 ⌘C/⌘V);看门狗自动重启被系统禁用的监听 |

**没有降级**:断网 / 未配置凭据 / 调用失败 → 直接提示失败(不回退本地)。已移除 Whisper、Apple SpeechTranscriber、Foundation Models、自定义词表、熔断等。

## 运行要求

- macOS(当前构建目标 macOS 26;已不依赖 Speech / Foundation Models,后续可下调以兼容更多机型)
- **需联网**
- **火山引擎**语音凭据(转写)+ **阿里云百炼** API Key(qwen-plus 润色)

## 凭据(只存本机,App 只读不写)

| 文件(`~/Library/Application Support/VoiceKey/`) | 内容 |
|---|---|
| `volcano.txt` | 火山 `APP_ID` / `ACCESS_TOKEN` / `RESOURCE_ID=volc.seedasr.sauc.duration`(2.0 小时版) |
| `aliyun.txt` | 阿里云百炼 API Key(`sk-` 开头),用于 qwen-plus 润色 |

菜单栏分别有「填写火山 API 凭据」「填写阿里云 Key」入口。火山凭据在语音技术控制台 → 应用管理获取,并需「开通正式版」(按时长后付费,先扣已购资源包)。

## 目录结构

```
Sources/VoiceKey/
├ main.swift / AppDelegate.swift   入口 + 编排(快捷键/录音/流式/润色/粘贴/菜单)
├ HotKey.swift                     CGEventTap 全局监听(只需「辅助功能」权限)+ 看门狗
├ AudioRecorder.swift              AVAudioEngine 录音 → 实时 16k PCM + 音量回调
├ VolcanoStreaming.swift           火山实时流式会话 + 凭据(VolcanoConfig)
├ AliyunCloud.swift                qwen-plus 润色(CloudPolisher)+ 凭据(AliyunConfig)
├ NetworkMonitor.swift             网络可达性
├ RecorderHUD.swift                底部悬浮控件(实时波形 + 状态)
├ TextInserter.swift               剪贴板 + ⌘V 插入
└ Util.swift                       withTimeout 等
```

> 不入库(`.gitignore`):`.build/`、`*.app`。运行时 `volcano.txt` / `aliyun.txt` 在 App 支持目录,不在仓库内。

## 构建

```bash
./build-app.sh            # 编译 + 用 Apple Development 证书签名 + 打包
cp -R VoiceKey.app /Applications/ && open /Applications/VoiceKey.app
```

`build-app.sh` 用固定的开发者证书签名(Team ID 稳定),**更新后不会让系统授权失效、无需反复重授**。

## 首次使用授权

1. **辅助功能**:系统设置 › 隐私与安全性 › 辅助功能 → 勾选 VoiceKey(全局快捷键 + 自动粘贴)。
2. **麦克风**:首次录音弹窗允许。
3. 填好 `volcano.txt` + `aliyun.txt` 两套凭据。

## 性能(实测)

- 火山转写:松手后 ~0.25~0.45s(边录边传,几乎瞬时)
- qwen-plus 润色:~1.0~2.5s(比 qwen-flash 略慢,但纠错更准)
- 总延迟:约 1.5~3s

## 诊断

`/tmp/voicekey-timing.log` 记录每次「转写[火山] / 润色[qwen-plus]」耗时及失败原因;HotKey 事件监听异常也写这里。

## 可调项

- 换更快润色模型:`AliyunCloud.swift` 的 `qwen-plus` → `qwen-flash`(略快、纠错稍弱)
- 改快捷键 / 润色提示词 / 悬浮条样式:见对应源文件
