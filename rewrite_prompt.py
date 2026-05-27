#!/usr/bin/env python3
"""Rewrite the macOS clipboard's English prompt via local Ollama (qwen3:8b).

Reads clipboard, sends to Ollama /api/chat, writes the cleaned rewrite back.
On any failure, the clipboard is left untouched and a notification is shown.
"""

import re
import subprocess
import sys
import warnings

warnings.filterwarnings("ignore", module="urllib3")

import pyperclip
import requests

OLLAMA_URL = "http://localhost:11434/api/chat"
MODEL = "qwen3:8b"
TIMEOUT_SEC = 30

SYSTEM_PROMPT = """You are an expert prompt rewriter. Rewrite the user's draft prompt to be:
- Grammatically correct and natural English
- Clear, specific, and unambiguous
- Well-structured if the task is complex
- Preserve the ORIGINAL INTENT exactly — do not add new requirements or assumptions

Output ONLY the rewritten prompt. No explanations, no preamble, no surrounding quotes."""

THINK_BLOCK_RE = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)


def notify(message: str, title: str = "Prompt Rewriter") -> None:
    """Best-effort macOS notification; failures are swallowed."""
    safe_msg = message.replace("\\", "\\\\").replace('"', '\\"')
    safe_title = title.replace("\\", "\\\\").replace('"', '\\"')
    script = f'display notification "{safe_msg}" with title "{safe_title}"'
    try:
        subprocess.run(
            ["osascript", "-e", script],
            check=False,
            capture_output=True,
            timeout=5,
        )
    except Exception:
        pass


def strip_wrapping_quotes(text: str) -> str:
    """Remove matched ASCII quotes that wrap the entire string.

    Conservative: only strips when the quote character appears exactly twice
    (at start and end), so prompts with legitimate inner quotes are untouched.
    """
    text = text.strip()
    if (
        len(text) >= 2
        and text[0] == text[-1]
        and text[0] in ('"', "'")
        and text.count(text[0]) == 2
    ):
        return text[1:-1].strip()
    return text


def clean_model_output(raw: str) -> str:
    """Strip <think> safety blocks and wrapping quotes."""
    without_think = THINK_BLOCK_RE.sub("", raw)
    return strip_wrapping_quotes(without_think)


def rewrite(prompt: str) -> str:
    payload = {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": prompt},
        ],
        "think": False,
        "stream": False,
        "options": {"temperature": 0.2},
    }
    response = requests.post(OLLAMA_URL, json=payload, timeout=TIMEOUT_SEC)
    response.raise_for_status()
    content = response.json()["message"]["content"]
    return clean_model_output(content)


def main() -> int:
    original = pyperclip.paste()
    if not original or not original.strip():
        return 0

    try:
        rewritten = rewrite(original)
    except requests.exceptions.Timeout:
        notify("Rewrite timed out (30s); clipboard unchanged")
        print("ERROR: Ollama request timed out", file=sys.stderr)
        return 1
    except requests.exceptions.ConnectionError:
        notify("Cannot reach Ollama at localhost:11434")
        print("ERROR: Ollama unreachable; is `ollama serve` running?", file=sys.stderr)
        return 1
    except Exception as exc:
        notify(f"Rewrite failed: {exc}")
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    if not rewritten.strip():
        notify("Empty rewrite result; clipboard unchanged")
        print("ERROR: empty rewrite output", file=sys.stderr)
        return 1

    pyperclip.copy(rewritten)
    notify("Prompt rewritten")
    print(f"ORIGINAL:\n{original}\n\nREWRITTEN:\n{rewritten}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
