# VoiceKey — 本地 / 云端混合语音输入工具(Typeless 免费替代)

在**任意 App 的任意输入框**,按一下快捷键说话,自动转写 → AI 润色 → 插入到光标处。
默认全本地、离线、免费;可选接阿里云在线模型获得更强的中英混排与同音字纠错。专为**中文 / 中英混杂**优化。

## 运行要求

- **Apple 芯片 Mac**(M1 及以上)
- **macOS 26+**(用到系统 `SpeechTranscriber` 与 Foundation Models)
- 本地润色需开启 **Apple 智能(Apple Intelligence)**;未开启则跳过润色
- 在线档需要阿里云百炼 API Key(可选)

## 工作流

```
按一下右 Command → 录音(底部悬浮波形,右侧显示当前引擎)→ 再按一下结束
   → 转写 → AI 润色 → 自动 ⌘V 粘贴到当前光标
```

## 两个引擎档位(菜单可切换,选择会记住)

转写 + 润色按"档位"成套走,**润色永远跟着转写**:

| 档位 | 转写 | 润色 | 何时用 |
|---|---|---|---|
| **在线**(在线优先 ON + 有网 + 配了 Key) | 阿里云 **Qwen3-ASR-Flash** | 阿里云 **qwen-plus** | 最准,中英混排 / 同音字纠错最强 |
| **本地 / 降级**(断网 / 在线失败 / 没配 Key) | **Whisper turbo** 或 **Apple 系统**(二选一) | 本地 **Foundation Models** | 离线、免费、隐私 |

- **「在线优先」是总开关**;它关掉、或断网/失败时,自动落到你选的**本地引擎**(Whisper / Apple 二选一)。
- 菜单顶部「当前生效:…」一行 + 悬浮条右侧引擎标,实时显示此刻在用哪条链路。

> 隐私/计费:用在线档时音频会上传到阿里云、按量计费;纯本地档完全免费、不出本机。

## 关键设计

- **快捷键**:点按右 Command 切换(toggle);只识别"单独点按",⌘C/⌘V 等组合键不会误触发。
- **悬浮控件**(`RecorderHUD`):底部小药丸,录音实时声波 + 引擎标,处理时显示「<引擎> 转写中…」。不抢焦点、不影响粘贴。
- **自定义词表**:`~/Library/Application Support/VoiceKey/terms.txt`(菜单「编辑自定义词表」)。喂给识别(contextualStrings / Whisper prompt / 阿里云 system)和润色,提升专有名词与同音字准确率。
- **文字插入**:剪贴板 + 合成 ⌘V,粘贴后还原剪贴板,对所有 App 通用。

## 目录结构(源码)

```
Sources/VoiceKey/
├ main.swift / AppDelegate.swift   入口 + 编排(快捷键/录音/引擎选择/菜单)
├ HotKey.swift                     CGEventTap 全局监听(只需「辅助功能」权限)
├ AudioRecorder.swift              录音 + 实时音量回调
├ AudioConvert.swift               afconvert → 16k 单声道 wav(共用)
├ TranscribeEngine.swift           转写引擎协议
├ Transcriber.swift                Apple 系统转写(SpeechTranscriber)
├ WhisperServer.swift              管理本地 whisper-server 进程
├ WhisperTranscriber.swift         本地 Whisper(beam=3 + flash-attn + 中文 prompt)
├ AliyunCloud.swift                阿里云 Qwen3-ASR 转写 + qwen-plus 润色 + Key 读取
├ NetworkMonitor.swift             网络可达性(联网优先/断网降级)
├ Polisher.swift                   本地 Foundation Models 润色 + 上下文纠错
├ Vocabulary.swift                 自定义词表加载
└ RecorderHUD.swift                底部悬浮控件
```

> 不入库(见 `.gitignore`):`tools/`(CMake)、`whisper.cpp/`(上游源码)、`models/`(模型)、`.build/`、`*.app`。用 `setup-whisper.sh` 在本机重建。运行时的 `terms.txt` / `aliyun.txt` 在 App 支持目录,不在仓库内。

## 从源码构建

```bash
# 1) 装本地 Whisper 引擎(下载 CMake + 编译 whisper.cpp + 下 turbo 模型,~1.6G)
./setup-whisper.sh
# 2) 编译并打包 App
./build-app.sh
# 3) 安装到「应用程序」并运行
cp -R VoiceKey.app /Applications/ && open /Applications/VoiceKey.app
```

只用 Apple 系统引擎(不要 Whisper)可跳过第 1 步,菜单切到「Apple 系统」。

## 首次使用授权

1. **辅助功能**:系统设置 › 隐私与安全性 › 辅助功能 → 勾选 VoiceKey(全局快捷键 + 自动粘贴)。重新编译后签名变化需重新勾选。
2. **麦克风**:首次录音弹窗允许。
3. **Apple 智能**(可选,本地润色用):系统设置 › Apple 智能与 Siri 开启。
4. **阿里云在线**(可选):菜单「填写阿里云 API Key…」,把百炼生成的 key 粘进 `aliyun.txt`,再开「在线优先」。

## 资源占用(M5/24G 实测)

- 本地空闲:whisper 服务 CPU ≈ 0%,常驻内存 ≈ 1.7G;每次转写 GPU 短脉冲数秒
- 在线:每句一次 ASR(音频 token)+ 一次 qwen-plus 润色(约百余 token,很便宜)

## 可调项

- 速度↔准确:`WhisperTranscriber` 的 `beam_size`(1 最快 / 3 折中 / 5 最准)
- 换更准本地模型:`setup-whisper.sh` 把 turbo 换成 `large-v3`
- 换在线润色模型:`AliyunCloud.swift` 的 `qwen-plus`(可换 `qwen-flash` 省钱 / `qwen-max` 最强)
- 换快捷键 / 改润色风格 / 改悬浮条样式:见对应源文件
