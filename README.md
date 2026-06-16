# VoiceKey — 中文 / 中英混杂语音输入工具(Typeless 替代)

在**任意 App 的任意输入框**,按一下快捷键说话,自动转写 → AI 润色 → 插入到光标处。
专为**中文 / 中英混杂**优化。两层架构:在线最准,断网自动落到本地、零额外内存。

## 运行要求

- **Apple 芯片 Mac**(M1 及以上)
- **macOS 26+**(用到系统 `SpeechTranscriber` 与 Foundation Models)
- 本地档润色需开启 **Apple 智能(Apple Intelligence)**;未开启则跳过润色
- 在线档需要阿里云百炼 API Key(可选,但推荐)

## 工作流

```
按一下右 Command → 录音(底部悬浮波形,右侧显示当前引擎)→ 再按一下结束
   → 转写 → AI 润色 → 自动 ⌘V 粘贴到当前光标
```

## 两层处理(转写 + 润色成套走)

| 层 | 转写 | 润色 | 何时用 |
|---|---|---|---|
| **第一层 · 在线**(在线优先 ON + 有网 + 配了 Key) | 阿里云 **Qwen3-ASR-Flash** | 阿里云 **qwen-plus** | 最准,中英混排 / 同音字纠错最强 |
| **第二层 · 本地**(断网 / 在线失败 / 没配 Key / 关掉在线优先) | 系统 **SpeechTranscriber** | 系统 **Foundation Models** | 离线、免费、隐私、零额外内存 |

- **第一层失败或没网时,自动降级到第二层**,用户无感;
- 全本地,**不再依赖 Whisper**(已移除,省内存);
- 菜单顶部「当前生效:…」+ 悬浮条右侧引擎标,实时显示此刻用哪层。

> 隐私/计费:用在线层时音频会上传到阿里云、按量计费(每句一次 ASR + 一次 qwen-plus 润色,很便宜);本地层完全免费、不出本机。

## 关键设计

- **快捷键**:点按右 Command 切换(toggle);只识别"单独点按",⌘C/⌘V 等组合键不会误触发。
- **悬浮控件**(`RecorderHUD`):底部小药丸,录音实时声波 + 引擎标,处理时显示「<引擎> 转写中…」。不抢焦点、不影响粘贴。
- **自定义词表**:`~/Library/Application Support/VoiceKey/terms.txt`(菜单「编辑自定义词表」)。喂给识别(contextualStrings / 阿里云 system)和润色,提升专有名词与同音字准确率。
- **文字插入**:剪贴板 + 合成 ⌘V,粘贴后还原剪贴板,对所有 App 通用。

## 目录结构(源码)

```
Sources/VoiceKey/
├ main.swift / AppDelegate.swift   入口 + 编排(快捷键/录音/两层选择/菜单)
├ HotKey.swift                     CGEventTap 全局监听(只需「辅助功能」权限)
├ AudioRecorder.swift              录音 + 实时音量回调
├ AudioConvert.swift               afconvert → 16k 单声道 wav(在线层用)
├ TranscribeEngine.swift           转写引擎协议
├ Transcriber.swift                第二层:系统 SpeechTranscriber
├ AliyunCloud.swift                第一层:阿里云 Qwen3-ASR + qwen-plus + Key 读取
├ NetworkMonitor.swift             网络可达性(在线优先 / 断网降级)
├ Polisher.swift                   本地 Foundation Models 润色 + 上下文纠错
├ Vocabulary.swift                 自定义词表加载
└ RecorderHUD.swift                底部悬浮控件
```

> 不入库(见 `.gitignore`):`.build/`、`*.app`。运行时的 `terms.txt` / `aliyun.txt` 在 App 支持目录,不在仓库内。

## 从源码构建

```bash
./build-app.sh                                   # 编译 + 打包
cp -R VoiceKey.app /Applications/ && open /Applications/VoiceKey.app
```

无需任何外部依赖 / 模型下载(两层都用系统能力 + 阿里云 API)。

## 首次使用授权

1. **辅助功能**:系统设置 › 隐私与安全性 › 辅助功能 → 勾选 VoiceKey(全局快捷键 + 自动粘贴)。重新编译后签名变化需重新勾选。
2. **麦克风**:首次录音弹窗允许。
3. **Apple 智能**(本地层润色用):系统设置 › Apple 智能与 Siri 开启。
4. **阿里云在线**(推荐):菜单「填写阿里云 API Key…」把百炼生成的 key 粘进 `aliyun.txt`,再开「在线优先」。

## 可调项

- 换在线润色模型:`AliyunCloud.swift` 的 `qwen-plus`(可换 `qwen-flash` 省钱 / `qwen-max` 最强)
- 换快捷键 / 改润色风格 / 改悬浮条样式:见对应源文件
