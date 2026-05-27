# Prompt Rewriter

A macOS hotkey tool that rewrites the clipboard's English prompt into clearer, grammatical English using a local LLM (Ollama + `qwen3:8b`). No cloud, no API keys, no browser extension — works in any app.

**Workflow:** copy draft → press **fn + Ctrl + R** → paste cleaned version.

## Prerequisites

- **macOS** (tested on Apple Silicon).
- **Ollama** — install from <https://ollama.com/download>.
- **Homebrew** — used to install Hammerspoon. <https://brew.sh>.
- **Python 3** — system `python3` is fine (macOS ships with it).

## Install

```bash
cd ~/repos/prompt-rewriter
./install.sh
```

The folder can live anywhere under `$HOME` — the installer derives its own path and writes that path into `~/.hammerspoon/init.lua`. If you move the folder later, just re-run `./install.sh` from the new location.

The installer is fully scripted and idempotent. It will:

1. Verify `ollama` is on `PATH` and pull the `qwen3:8b` model (~5.2 GB).
2. Create a Python venv at `./.venv` and install `pyperclip` + `requests`.
3. Add `export OLLAMA_KEEP_ALIVE=24h` to `~/.zshrc` (only if no `OLLAMA_KEEP_ALIVE` line already exists — keeps the model warm in RAM so cold starts disappear).
4. Install **Hammerspoon** via `brew install --cask hammerspoon` if it's not already present.
5. Write/append the `fn + Ctrl + R` hotkey block to `~/.hammerspoon/init.lua` (idempotent — the block is marked and only added once).
6. Launch Hammerspoon (or reload its config if already running) and open **System Settings → Privacy & Security → Accessibility**.

**The only manual step** is toggling Hammerspoon ON in the Accessibility pane — macOS does not allow scripts to grant TCC permissions.

## Usage

1. Select text in any app and press `Cmd+C`.
2. Press **fn + Ctrl + R**.
3. Wait for the "Prompt rewritten" notification (typically <2s once the model is warm).
4. Press `Cmd+V` to paste the rewrite.

If the clipboard is empty or whitespace-only, the script exits silently — no notification.

## Why fn + Ctrl + R (and a caveat)

`fn` is a "secondary" macOS modifier that Carbon's standard hotkey API (used by `hs.hotkey.bind`) does not see. The included `init.lua` uses `hs.eventtap` to watch raw key events instead. This works reliably on the **MacBook internal keyboard**, where pressing `fn` emits the `SecondaryFn` flag. **External keyboards** (especially non-Apple ones) may not emit this flag — if you use the tool on an external keyboard and the hotkey does nothing, swap to a more conventional chord (see "Change the hotkey" below).

## Customisation

- **Change the hotkey**: edit `~/.hammerspoon/init.lua` between the `prompt-rewriter:hotkey BEGIN/END` markers. If you don't need `fn`, you can drop back to the simpler `hs.hotkey.bind` form, e.g.:
  ```lua
  hs.hotkey.bind({"ctrl", "alt"}, "R", runRewrite)
  ```
  Reload via the Hammerspoon menu bar → Reload Config (or just re-run `./install.sh`, which calls `hs.reload()` for you).
- **Change the model**: edit the `MODEL = "qwen3:8b"` constant near the top of `rewrite_prompt.py`. Any chat model Ollama has pulled will work; smaller models trade quality for speed.
- **Tune temperature**: edit `"temperature": 0.2` inside `rewrite()` in `rewrite_prompt.py`.

## Behaviour notes

- **Mixed-language input**: feeding the model `viết cho tôi a function python để parse json` is acceptable input. `qwen3:8b` will typically translate the Vietnamese fragments into English and produce a clean English prompt; behaviour is not strictly specified.
- **Already-clean prompts** pass through with minimal change at `temperature=0.2`.
- **`<think>` blocks**: the script disables Qwen 3 thinking mode (`think: false`) and additionally strips any `<think>…</think>` blocks as a safety net.
- **Wrapping quotes**: the model occasionally wraps the output in `"…"` or `'…'` despite the system prompt. The script strips them only when the quote appears exactly twice (at start and end), so legitimate inner quotes are preserved.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| "Cannot reach Ollama" notification | Run `ollama serve` (or start the Ollama desktop app). |
| First rewrite takes ~10s, later ones fast | Model cold-start. Confirm `echo $OLLAMA_KEEP_ALIVE` shows `24h` in the shell where `ollama serve` runs. |
| Hotkey does nothing | Open Hammerspoon → Console; check for errors. Make sure Accessibility permission is granted in **System Settings → Privacy & Security → Accessibility**. On external keyboards, `fn` may not register — see the "Why fn + Ctrl + R" section. |
| "Rewrite timed out (30s)" | Model is loading or machine is busy. Try again, or bump `TIMEOUT_SEC` in `rewrite_prompt.py`. |
| `ModuleNotFoundError: pyperclip` when running manually | Use the venv interpreter: `~/repos/prompt-rewriter/.venv/bin/python3 rewrite_prompt.py`. The installer does not touch system Python; if you want to invoke the script with system `python3`, install the deps yourself with `pip install --user -r requirements.txt`. |
| Notifications missing | Check **System Settings → Notifications → Script Editor** (osascript posts under that). |

## Manual run / debug

```bash
echo "i want make python code for scrape data" | pbcopy
~/repos/prompt-rewriter/.venv/bin/python3 ~/repos/prompt-rewriter/rewrite_prompt.py
pbpaste
```

`stdout` shows the original and rewritten text; useful when iterating on the system prompt.

## Possible extensions (not implemented)

- Multiple presets bound to different hotkeys (grammar-fix vs. expand-detail vs. translate).
- Diff preview before overwriting the clipboard (e.g. `tkinter` or `hs.dialog`).
- Streamed output to a floating Hammerspoon window instead of the single end-of-run notification.
