# FnIME (macOS Fn hold-to-talk input helper)

A minimal macOS menu bar app:

- Hold `fn` to start recording.
- Release `fn` to stop recording and send audio to Gemini.
- Result is put into pasteboard and auto-pasted with simulated `Cmd+V`.

## 1) Prerequisites

- macOS 13+
- Swift 6 toolchain
- Gemini API key

## 2) Configure

Use either environment variables:

```bash
export GEMINI_API_KEY="your_key"
export GEMINI_MODEL="gemini-3-flash-preview"
export GEMINI_PROMPT="You are an input method ASR post-processor. Convert the user's speech into Chinese text for typing. Infer the domain only from the spoken content in this audio, then use that inferred domain to disambiguate jargon, proper nouns, and abbreviations/acronyms. Prefer the interpretation that best matches local context. If uncertain, keep the original wording or abbreviation. Apply only light polishing (punctuation, filler removal, obvious ASR fixes) without changing user intent or adding facts. Return plain text only."
```

Or config file at `~/.config/fn-ime/config.json`:

```json
{
  "apiKey": "your_key",
  "model": "gemini-3-flash-preview",
  "prompt": "You are an input method ASR post-processor. Convert the user's speech into Chinese text for typing. Infer the domain only from the spoken content in this audio, then use that inferred domain to disambiguate jargon, proper nouns, and abbreviations/acronyms. Prefer the interpretation that best matches local context. If uncertain, keep the original wording or abbreviation. Apply only light polishing (punctuation, filler removal, obvious ASR fixes) without changing user intent or adding facts. Return plain text only."
}
```

## 3) Build and run

```bash
swift build
swift run fn-ime
```

At first launch, allow:

- Microphone permission
- Accessibility permission (needed for simulated `Cmd+V`)

If Accessibility is not granted, recognized text will still be copied to pasteboard.

## Logs

- File log: `~/.local/state/fn-ime/fn-ime.log` (fallback: `/tmp/fn-ime.log`)
- Runtime log: stderr from `swift run fn-ime`

Useful while debugging:

```bash
tail -f ~/.local/state/fn-ime/fn-ime.log
```

## Floating HUD

- Hold `fn`: shows recording icon at the bottom-center of current screen.
- Recording state includes a live spectrum-style meter to indicate audio is being captured.
- Release `fn`: switches to recognition progress bar.
- During recognition: use HUD `Cancel` button to stop current recognition.
- HUD height auto-resizes based on current controls (progress/cancel/retry/abort) to avoid clipping.
- Progress duration estimate is learned from prior runs and stored at:
  `~/.local/state/fn-ime/recognition-stats.json`
- On successful insertion, the floating HUD hides immediately.
- If recognition exceeds a timeout based on the predicted duration, HUD shows `Retry` and `Abort`.

## Notes

- This is a practical input helper, not a full InputMethodKit keyboard layout/IME bundle.
- `fn` detection relies on macOS flags-changed events and may vary by keyboard/hardware settings.
