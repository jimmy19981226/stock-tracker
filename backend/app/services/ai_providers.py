"""Provider abstraction for the AI assistant.

The user picks a provider (OpenAI / Gemini / Claude) in the app and supplies
their own API key, which arrives per-request as the ``X-AI-Key`` header. Gemini
keeps its richer grounding/citation path inline in ``ai.py``; this module covers
the plain text-streaming path used by OpenAI and Anthropic (Claude). Each
function yields raw text deltas so the SSE generator can forward them unchanged.
"""
from __future__ import annotations

from typing import Iterable, Iterator

# Sensible defaults; the model can be overridden per provider later if needed.
DEFAULT_MODELS = {
    "openai": "gpt-4o",
    "claude": "claude-opus-4-8",
    "gemini": "gemini-2.5-flash",
}

History = Iterable[tuple[str, str]]  # (role, content), role in {"user","assistant"}


def stream_openai(api_key: str, model: str | None, system_prompt: str,
                  history: History) -> Iterator[str]:
    try:
        from openai import OpenAI
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError(
            "The 'openai' package isn't installed on the server. "
            "Add openai to requirements.txt and redeploy."
        ) from exc

    client = OpenAI(api_key=api_key)
    messages: list[dict] = [{"role": "system", "content": system_prompt}]
    for role, content in history:
        messages.append({
            "role": "assistant" if role == "assistant" else "user",
            "content": content,
        })

    stream = client.chat.completions.create(
        model=model or DEFAULT_MODELS["openai"],
        messages=messages,
        stream=True,
        max_tokens=1500,
        temperature=0.4,
    )
    for event in stream:
        choices = getattr(event, "choices", None) or []
        if not choices:
            continue
        delta = getattr(choices[0].delta, "content", None)
        if delta:
            yield delta


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
    raise ValueError(f"Unsupported provider for text streaming: {provider}")
