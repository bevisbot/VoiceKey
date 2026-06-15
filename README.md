# VoiceKey — 本地语音输入工具(Typeless 免费替代)

在**任意 App 的任意输入框**,按一下快捷键说话,自动转写 → AI 润色 → 插入到光标处。
**全程本地、离线、免费**,无需联网、无订阅。专为**中文 / 中英混杂**场景优化。

## 运行要求

- **Apple 芯片 Mac**(M1 及以上)
- **macOS 26+**(用到系统 `SpeechTranscriber` 与 Foundation Models)
- 润色功能需开启 **Apple 智能(Apple Intelligence)**;未开启会自动降级为纯转写

## 工作流

```
按一下右 Command → 录音(底部悬浮波形)→ 再按一下结束
   → 转写(Whisper / Apple)→ AI 润色 → 自动 ⌘V 粘贴到当前光标
```

## 转写双引擎(菜单栏可切换,选择会记住)

| 引擎 | 特点 | 说明 |
|---|---|---|
| **Whisper turbo**(默认) | **中英混排明显更好** | whisper.cpp 编译出 `whisper-server`,App 启动时自动拉起本地 HTTP 服务(127.0.0.1:8178),退出自动关。模型 `large-v3-turbo`。 |
| **Apple 系统** | 更快、零额外内存 | macOS 26 `SpeechTranscriber`(zh-CN)。 |

润色统一用 macOS 26 **Foundation Models**(Apple 端侧大模型):去口头语、补标点、按上下文纠正同音/近音误识别。

## 关键设计

- **快捷键**:点按右 Command 切换(toggle)。只识别"单独点按",按 ⌘C/⌘V 等组合键不会误触发。改键见 `Sources/VoiceKey/HotKey.swift` 的 `triggerKeyCode`。
- **悬浮控件**(`RecorderHUD`):底部小药丸,录音时显示实时声波,处理时显示状态。不抢焦点、忽略鼠标,不影响粘贴。
- **自定义词表**:菜单「编辑自定义词表」打开 `~/Library/Application Support/VoiceKey/terms.txt`,常用人名/产品名/术语一行一个。会喂给识别引擎(contextualStrings)和润色模型,提升专有名词准确率。
- **文字插入**:剪贴板 + 合成 ⌘V,粘贴后自动还原剪贴板。对所有 App 通用。

## 目录结构

```
VoiceKey/
├ Package.swift                SwiftPM(可执行目标,无第三方依赖)
├ Sources/VoiceKey/
│  ├ main.swift                入口(菜单栏 agent,LSUIElement)
│  ├ AppDelegate.swift         编排:菜单/快捷键/录音→转写→润色→粘贴/引擎切换
│  ├ HotKey.swift              CGEventTap 全局监听(只需「辅助功能」权限)
│  ├ AudioRecorder.swift       AVAudioEngine 录音 + 实时音量回调
│  ├ TranscribeEngine.swift    转写引擎协议
│  ├ Transcriber.swift         Apple 引擎(SpeechTranscriber)
│  ├ WhisperServer.swift       管理 whisper-server 常驻进程
│  ├ WhisperTranscriber.swift  录音转 16k wav,POST 给 whisper-server
│  ├ Polisher.swift            Foundation Models 润色 + 上下文纠错
│  ├ Vocabulary.swift          自定义词表加载
│  └ RecorderHUD.swift         底部悬浮控件
├ Info.plist / VoiceKey.entitlements   App 包配置(权限说明 / LSUIElement)
├ build-app.sh                 编译 + 打包成 VoiceKey.app
├ setup-whisper.sh             一键装 Whisper(编译 whisper.cpp + 下模型)
└ make-icon.swift              生成 App 图标
```

> 不入库(见 `.gitignore`):`tools/`(CMake)、`whisper.cpp/`(上游源码)、`models/`(1.6G 模型)、`.build/`、`*.app`。用 `setup-whisper.sh` 在本机重建。

## 从源码构建

```bash
# 1) 装 Whisper 引擎(下载 CMake + 编译 whisper.cpp + 下 turbo 模型,~1.6G)
./setup-whisper.sh

# 2) 编译并打包 App
./build-app.sh

# 3) 安装到「应用程序」并运行
cp -R VoiceKey.app /Applications/
open /Applications/VoiceKey.app
```

只想用 Apple 系统引擎(不需要 Whisper)的话,可跳过第 1 步,在菜单里切到「Apple 系统」。

## 首次使用授权

1. **辅助功能**:系统设置 › 隐私与安全性 › 辅助功能 → 勾选 VoiceKey(全局快捷键 + 自动粘贴)。重新编译后签名变化需重新勾选。
2. **麦克风**:首次录音弹窗允许。
3. **Apple 智能**(可选,润色用):系统设置 › Apple 智能与 Siri 开启。

## 资源占用(M5/24G 实测)

- 空闲时:whisper 服务 CPU ≈ 0%,常驻内存 ≈ 1.7G(模型常驻换"即时转写")
- 每次转写:GPU 短脉冲 1~3 秒,随后回到空闲;对电池影响很小

## 已知可调项

- 换更准模型:`setup-whisper.sh` 里把 turbo 换成 `large-v3`(更准、更慢、~3G)
- 省内存:换 turbo 的 q5 量化版(~570MB)
- 换快捷键 / 改润色风格 / 改悬浮控件样式:见对应源文件
