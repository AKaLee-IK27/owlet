#!/usr/bin/env python3
"""Rewrite an English prompt via local Ollama (qwen3:8b).

Reads draft from stdin, writes the cleaned rewrite to stdout.
On any failure: prints a short error to stderr and exits non-zero.
The clipboard is never touched; no notifications are posted. This script is
a pure CLI intended to be invoked by Owlet.app via Foundation.Process, or
manually for debugging.
"""

import re
import sys
import warnings

warnings.filterwarnings("ignore", module="urllib3")

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


def strip_wrapping_quotes(text: str) -> str:
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
    return strip_wrapping_quotes(THINK_BLOCK_RE.sub("", raw))


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
    original = sys.stdin.read()
    if not original or not original.strip():
        return 0  # silent: empty input is a no-op

    try:
        rewritten = rewrite(original)
    except requests.exceptions.Timeout:
        print("ERROR: Ollama request timed out", file=sys.stderr)
        return 1
    except requests.exceptions.ConnectionError:
        print("ERROR: Ollama unreachable; is `ollama serve` running?", file=sys.stderr)
        return 1
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    if not rewritten.strip():
        print("ERROR: empty rewrite output", file=sys.stderr)
        return 1

    sys.stdout.write(rewritten)
    return 0


if __name__ == "__main__":
    sys.exit(main())
