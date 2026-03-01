# FnIME

FnIME 是一个 macOS 菜单栏语音输入助手：

- 按住 `fn` 开始录音
- 松开 `fn` 停止录音并调用 Gemini 识别
- 将识别文本插入当前光标位置（无辅助功能权限时仅复制到剪贴板）

它是“语音输入助手”，不是系统级 InputMethodKit 输入法。

## Documentation

- 使用与构建说明：本文档
- 需求文档：[docs/REQUIREMENTS.md](docs/REQUIREMENTS.md)
- 技术设计文档：[docs/TECHNICAL_DESIGN.md](docs/TECHNICAL_DESIGN.md)

## Requirements

- macOS 13+
- Swift 6
- Gemini API Key

## Configuration

可以通过环境变量或本地配置文件提供参数。

### Option A: Environment Variables

```bash
export GEMINI_API_KEY="your_key"
export GEMINI_MODEL="gemini-3-flash-preview"
export GEMINI_PROMPT="You are an input method ASR post-processor. Convert the user's speech into Chinese text for typing. Infer the domain only from the spoken content in this audio, then use that inferred domain to disambiguate jargon, proper nouns, and abbreviations/acronyms. Prefer the interpretation that best matches local context. If uncertain, keep the original wording or abbreviation. Apply only light polishing (punctuation, filler removal, obvious ASR fixes) without changing user intent or adding facts. Return plain text only."
```

### Option B: Config File

路径：`~/.config/fn-ime/config.json`

```json
{
  "apiKey": "your_key",
  "model": "gemini-3-flash-preview",
  "prompt": "You are an input method ASR post-processor. Convert the user's speech into Chinese text for typing. Infer the domain only from the spoken content in this audio, then use that inferred domain to disambiguate jargon, proper nouns, and abbreviations/acronyms. Prefer the interpretation that best matches local context. If uncertain, keep the original wording or abbreviation. Apply only light polishing (punctuation, filler removal, obvious ASR fixes) without changing user intent or adding facts. Return plain text only."
}
```

## Build

```bash
swift build
```

## Run

```bash
swift run fn-ime
```

首次启动需要在系统里允许：

- 麦克风权限
- 辅助功能权限（用于模拟 `Cmd+V`）

## How To Use

1. 打开任意可输入文本的软件，将光标放到目标位置。
2. 按住 `fn`，开始录音（底部 HUD 显示录音图标和频谱）。
3. 松开 `fn`，进入识别阶段（HUD 显示平滑进度条）。
4. 识别成功后自动插入文本并隐藏 HUD。

识别阶段支持：

- `Cancel`：取消当前识别
- 超时后 `Retry`：重试上一段录音
- 超时后 `Abort`：中止并关闭 HUD

## Logs & Debugging

- 文件日志：`~/.local/state/fn-ime/fn-ime.log`（回退 `/tmp/fn-ime.log`）
- 运行时日志：`swift run fn-ime` 标准错误输出

常用调试命令：

```bash
tail -f ~/.local/state/fn-ime/fn-ime.log
```

## CI

仓库包含 GitHub Actions CI：

- `swift package resolve`
- `swift build -c release`
- `swift test`

配置文件：`.github/workflows/ci.yml`

## Security Notes

- 不要在仓库提交真实 API Key。
- 建议仅在本机通过环境变量或 `~/.config/fn-ime/config.json` 提供密钥。
- 日志中会记录状态信息，不应写入敏感业务数据。
