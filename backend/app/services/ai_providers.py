"""Provider abstraction for the AI assistant.

The user picks a provider (OpenAI / Gemini / Claude / NVIDIA NIM) in the app
and supplies their own API key, which arrives per-request as the ``X-AI-Key``
header. Gemini keeps its richer grounding/citation path inline in ``ai.py``;
this module covers the plain text-streaming path used by OpenAI, Anthropic
(Claude), and NVIDIA NIM (an OpenAI-compatible endpoint — free keys at
build.nvidia.com). Each function yields raw text deltas so the SSE generator
can forward them unchanged.

NIM has no native web grounding, so :func:`plan_search_queries` +
:func:`search_web` provide a DIY equivalent: a quick planner call decides
whether the question needs fresh web data, DuckDuckGo (keyless, free) fetches
the results, and ``ai.py`` injects them into the system prompt with the same
``[N]`` citation contract the Gemini path uses.
"""
from __future__ import annotations

import json
import re
from typing import Iterable, Iterator

NVIDIA_BASE_URL = "https://integrate.api.nvidia.com/v1"

# Sensible defaults; the model can be overridden per provider later if needed.
DEFAULT_MODELS = {
    "openai": "gpt-4o",
    "claude": "claude-opus-4-8",
    "gemini": "gemini-2.5-flash",
    "nvidia": "deepseek-ai/deepseek-v4-pro",
}

History = Iterable[tuple[str, str]]  # (role, content), role in {"user","assistant"}


def _openai_client(api_key: str, base_url: str | None = None):
    try:
        from openai import OpenAI
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError(
            "The 'openai' package isn't installed on the server. "
            "Add openai to requirements.txt and redeploy."
        ) from exc
    return OpenAI(api_key=api_key, base_url=base_url)


_THINK_OPEN = "<think>"
_THINK_CLOSE = "</think>"


def _filter_think(chunks: Iterable[str]) -> Iterator[str]:
    """Drop <think>…</think> reasoning blocks from a text-delta stream.

    Reasoning models (DeepSeek V4, GLM, Qwen) may inline their chain of
    thought in the content; users should only see the final answer. Tags can
    be split across chunks, so a small tail is held back until it's provably
    not part of a tag.
    """
    pending = ""
    in_think = False
    for chunk in chunks:
        pending += chunk
        out: list[str] = []
        while pending:
            if in_think:
                idx = pending.find(_THINK_CLOSE)
                if idx == -1:
                    pending = pending[-(len(_THINK_CLOSE) - 1):]
                    break
                pending = pending[idx + len(_THINK_CLOSE):]
                in_think = False
            else:
                idx = pending.find(_THINK_OPEN)
                if idx == -1:
                    safe = len(pending) - (len(_THINK_OPEN) - 1)
                    if safe > 0:
                        out.append(pending[:safe])
                        pending = pending[safe:]
                    break
                out.append(pending[:idx])
                pending = pending[idx + len(_THINK_OPEN):]
                in_think = True
        joined = "".join(out)
        if joined:
            yield joined
    if pending and not in_think:
        yield pending


def _stream_chat_completions(client, model: str, system_prompt: str,
                             history: History) -> Iterator[str]:
    messages: list[dict] = [{"role": "system", "content": system_prompt}]
    for role, content in history:
        messages.append({
            "role": "assistant" if role == "assistant" else "user",
            "content": content,
        })

    stream = client.chat.completions.create(
        model=model,
        messages=messages,
        stream=True,
        max_tokens=1500,
        temperature=0.4,
    )

    def deltas() -> Iterator[str]:
        for event in stream:
            choices = getattr(event, "choices", None) or []
            if not choices:
                continue
            delta = getattr(choices[0].delta, "content", None)
            if delta:
                yield delta

    return _filter_think(deltas())


def stream_openai(api_key: str, model: str | None, system_prompt: str,
                  history: History) -> Iterator[str]:
    client = _openai_client(api_key)
    return _stream_chat_completions(
        client, model or DEFAULT_MODELS["openai"], system_prompt, history
    )


def stream_nvidia(api_key: str, model: str | None, system_prompt: str,
                  history: History) -> Iterator[str]:
    client = _openai_client(api_key, base_url=NVIDIA_BASE_URL)
    return _stream_chat_completions(
        client, model or DEFAULT_MODELS["nvidia"], system_prompt, history
    )


def stream_claude(api_key: str, model: str | None, system_prompt: str,
                  history: History) -> Iterator[str]:
    try:
        import anthropic
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError(
            "The 'anthropic' package isn't installed on the server. "
            "Add anthropic to requirements.txt and redeploy."
        ) from exc

    client = anthropic.Anthropic(api_key=api_key)
    # Anthropic requires the first message to be 'user'; our history already
    # starts with the user's question. Consecutive same-role messages are
    # allowed (the API merges them). Note: Opus 4.8 rejects `temperature`.
    messages = [
        {"role": "assistant" if role == "assistant" else "user", "content": content}
        for role, content in history
    ]
    if not messages:
        return
    with client.messages.stream(
        model=model or DEFAULT_MODELS["claude"],
        max_tokens=2048,
        system=system_prompt,
        messages=messages,
    ) as stream:
        for text in stream.text_stream:
            if text:
                yield text


def stream(provider: str, api_key: str, model: str | None, system_prompt: str,
           history: History) -> Iterator[str]:
    if provider == "openai":
        return stream_openai(api_key, model, system_prompt, history)
    if provider == "claude":
        return stream_claude(api_key, model, system_prompt, history)
    if provider == "nvidia":
        return stream_nvidia(api_key, model, system_prompt, history)
    raise ValueError(f"Unsupported provider for text streaming: {provider}")


# ---------------------------------------------------------------------------
# DIY web grounding for providers without a native search tool (NVIDIA NIM).
# ---------------------------------------------------------------------------

_JSON_OBJ = re.compile(r"\{[^{}]*\}")


def plan_search_queries(api_key: str, model: str | None, user_text: str,
                        today: str) -> list[str]:
    """One quick NIM call that decides whether the question needs the web.

    Returns up to 3 search queries, or [] when the portfolio context alone
    should answer it. Never raises — grounding is best-effort and must not
    break the chat stream.
    """
    prompt = (
        "You route questions for a stock-portfolio assistant that already has "
        "the user's full holdings/trades/dividends data locally. Decide if the "
        f"question ALSO needs fresh web information (today is {today}): recent "
        "news, earnings, dividends announcements, filings, analyst views, macro "
        "events, prices of things not held, etc.\n"
        'Reply with ONLY a JSON object: {"queries": ["..."]} — 1-3 concise web '
        "search queries if the web is needed, or an empty list if the local "
        "portfolio data suffices. For Taiwan stocks, include the ticker code "
        "and company name in the query."
    )
    try:
        client = _openai_client(api_key, base_url=NVIDIA_BASE_URL)
        resp = client.chat.completions.create(
            model=model or DEFAULT_MODELS["nvidia"],
            messages=[
                {"role": "system", "content": prompt},
                {"role": "user", "content": user_text[:2000]},
            ],
            max_tokens=600,  # headroom: reasoning models may think before the JSON
            temperature=0.0,
        )
        text = (resp.choices[0].message.content or "").strip()
        # Reasoning models may wrap the JSON in commentary — take the last
        # flat {...} that parses and carries a "queries" key.
        for blob in reversed(_JSON_OBJ.findall(text)):
            try:
                parsed = json.loads(blob)
            except json.JSONDecodeError:
                continue
            if isinstance(parsed, dict) and "queries" in parsed:
                queries = parsed.get("queries") or []
                return [str(q).strip() for q in queries if str(q).strip()][:3]
    except Exception:
        pass
    return []


def search_web(queries: list[str], per_query: int = 4,
               max_sources: int = 8) -> list[dict]:
    """Fetch DuckDuckGo results (keyless, free) for the planned queries.

    Returns deduplicated ``{title, url, snippet}`` dicts, capped at
    ``max_sources``. Never raises.
    """
    results: list[dict] = []
    seen_urls: set[str] = set()
    try:
        from ddgs import DDGS

        with DDGS() as ddg:
            for query in queries:
                try:
                    hits = ddg.text(query, max_results=per_query) or []
                except Exception:
                    continue
                for hit in hits:
                    url = hit.get("href") or hit.get("url") or ""
                    if not url or url in seen_urls:
                        continue
                    seen_urls.add(url)
                    results.append({
                        "title": hit.get("title") or url,
                        "url": url,
                        "snippet": (hit.get("body") or "")[:400],
                    })
                    if len(results) >= max_sources:
                        return results
    except Exception:
        pass
    return results
