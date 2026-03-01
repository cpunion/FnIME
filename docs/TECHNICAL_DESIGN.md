# FnIME 技术设计文档

## 1. 总体架构

FnIME 是一个 Swift + AppKit 菜单栏应用，核心模块：

- `AppController`：应用状态机与流程编排
- `FnKeyMonitor`：`fn` 键监听（事件 + 松开纠偏轮询）
- `AudioRecorder`：音频采集、WAV 编码、录音电平输出
- `GeminiClient`：调用 Gemini `generateContent`
- `TextInjector`：剪贴板写入与 `Cmd+V` 注入
- `FloatingStatusOverlay`：HUD（录音频谱、识别进度、控制按钮）
- `RecognitionStatsStore`：历史耗时统计与进度预估
- `AppLogger`：双通道日志（stderr + 文件）

## 2. 核心流程

1. `fn down` -> `AudioRecorder.start()` -> HUD 录音态。
2. `fn up` -> `AudioRecorder.stop()` -> 生成 WAV。
3. `GeminiClient.transcribe()` 发请求，HUD 进入识别态。
4. 成功：`TextInjector.inject()` 插入文本，HUD 关闭。
5. 失败：HUD 显示失败态；超时显示 `Retry/Abort`。

## 3. 状态模型

主要布尔状态：

- `isRecording`
- `isTranscribing`

识别相关上下文：

- `currentTranscriptionID`
- `currentTranscribeTask`（可取消）
- `transcribeTimeoutTimer`
- `lastRecordingForRetry`

## 4. 录音设计

- 使用 `AVAudioEngine.inputNode.installTap` 采集 PCM。
- 混合多声道为单声道。
- 转换为 16-bit PCM WAV。
- 同步计算 RMS 并归一化为 `0...1`，驱动 HUD 频谱。

## 5. 识别请求设计

- Endpoint: `v1beta/models/{model}:generateContent`
- 请求体包含：
  - 文本提示词 `prompt`
  - `audio/wav` 的 Base64 `inlineData`
- 返回解析：首个 candidate 的 text parts 拼接。

取消与超时：

- 通过 `URLSessionDataTask.cancel()` 取消请求。
- 超时阈值依据统计预测，公式：
  - `max(estimated * 2.4, estimated + 3.5)`
  - 并裁剪到 `5s...40s`

## 6. HUD 设计

- 窗口类型：无边框 `NSPanel`，底部居中悬浮。
- 录音态：麦克风图标 + 频谱视图。
- 识别态：平滑进度条 + `Cancel`。
- 超时态：`Retry` + `Abort`。
- 通过 `fittingSize` 动态调整窗口大小，避免控件被裁切。

## 7. 进度估算

`RecognitionStatsStore` 记录 `(audioSeconds, transcribeSeconds)` 样本：

- 优先线性回归估算
- 数据不足时使用均值
- 冷启动使用简单经验值

目的：提供更接近真实耗时的进度条体验。

## 8. 文本注入策略

1. 写入系统剪贴板。
2. 若辅助功能权限可用，发送 `Cmd+V` 键盘事件。
3. 权限不可用时，退化为“仅复制”。

## 9. 日志与可观测性

日志记录关键节点：

- 权限状态
- 录音开始/结束（含时长、大小）
- Gemini 请求发起/状态码/错误
- 注入结果

日志文件：`~/.local/state/fn-ime/fn-ime.log`

## 10. 安全设计

- API Key 仅来自环境变量或本地配置文件。
- 不在代码库存储任何真实密钥。
- 日志不打印明文密钥。

## 11. CI 设计

GitHub Actions 在 `macos-latest` 执行：

- `swift package resolve`
- `swift build -c release`
- `swift test`

目标是保证主分支构建可用、回归可检测。
