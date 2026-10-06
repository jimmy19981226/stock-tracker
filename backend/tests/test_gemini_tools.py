"""Gemini streaming/tool protocol regressions, without live API or DB calls."""
from copy import deepcopy
from types import SimpleNamespace
from unittest import TestCase
from unittest.mock import patch

from google.genai import types

from app.services import ai_tools


MODEL = "gemini-3.5-flash-lite"


def chunk(*parts):
    return types.GenerateContentResponse(candidates=[
        types.Candidate(content=types.Content(role="model", parts=list(parts)))
    ])


class GeminiToolTests(TestCase):
    def run_loop(self, responses, model=MODEL, tool_result=({"value": 1234.56}, None)):
        requests = []
        streams = iter(responses)

        def generate(**kwargs):
            requests.append(deepcopy(kwargs))
            result = next(streams)
            if isinstance(result, Exception):
                raise result
            return iter(result)

        client = SimpleNamespace(models=SimpleNamespace(generate_content_stream=generate))
        with patch("google.genai.Client", return_value=client), \
             patch.object(ai_tools, "execute", return_value=tool_result) as execute:
            events = list(ai_tools.run_tool_loop(
                "gemini", "test-key", model, "Test portfolio assistant",
                [("user", "Show my portfolio", None, None)], "test-user"))
        return requests, events, execute

    def test_streaming_reply_uses_minimal_thinking(self):
        requests, events, execute = self.run_loop([
            [chunk(types.Part(text="Your value is ")), chunk(types.Part(text="1,234.56."))]
        ])
        self.assertEqual(requests[0]["model"], MODEL)
        self.assertEqual(requests[0]["config"].thinking_config.thinking_level,
                         types.ThinkingLevel.MINIMAL)
        self.assertEqual(events, [("chunk", "Your value is "), ("chunk", "1,234.56.")])
        execute.assert_not_called()

    def test_signed_parallel_tool_calls_survive_the_next_request(self):
        parts = [
            types.Part(text="Checking totals.", thought=True),
            types.Part(function_call=types.FunctionCall(
                name="get_portfolio_summary", args={"market": "US"}, id="call-1"),
                thought_signature=b"signed-model-state"),
            types.Part(function_call=types.FunctionCall(
                name="get_holdings", args={"market": "US"}, id="call-2")),
            types.Part(thought_signature=b"trailing-signature"),
        ]
        requests, events, execute = self.run_loop([
            [chunk(*parts)], [chunk(types.Part(text="Here are your totals."))]
        ])
        self.assertEqual(len(requests), 2)
        replay = requests[1]["contents"][-2]
        self.assertEqual(replay.role, "model")
        self.assertEqual(replay.parts, parts)
        replies = requests[1]["contents"][-1].parts
        self.assertEqual([p.function_response.id for p in replies], ["call-1", "call-2"])
        self.assertEqual([p.function_response.name for p in replies],
                         ["get_portfolio_summary", "get_holdings"])
        self.assertEqual(execute.call_count, 2)
        self.assertIn(("thinking", "Checking totals."), events)
        self.assertEqual(events[-1], ("chunk", "Here are your totals."))

    def test_write_tool_emits_a_proposal_before_the_answer(self):
        proposal = {"trades": [{"ticker": "AAPL", "shares": 1}]}
        _, events, execute = self.run_loop([
            [chunk(types.Part(function_call=types.FunctionCall(
                name="add_trade", args={"ticker": "AAPL"}, id="write-1"),
                thought_signature=b"signed-write-call"))],
            [chunk(types.Part(text="Please confirm this trade."))],
        ], tool_result=({"pending_confirmation": True}, proposal))
        self.assertIn(("action", proposal), events)
        self.assertLess(events.index(("action", proposal)),
                        events.index(("chunk", "Please confirm this trade.")))
        execute.assert_called_once_with("add_trade", {"ticker": "AAPL"}, "test-user")

    def test_older_gemini_does_not_receive_a_new_thinking_level(self):
        requests, _, _ = self.run_loop([
            [chunk(types.Part(text="Done."))]
        ], model="gemini-2.5-flash")
        self.assertIsNone(requests[0]["config"].thinking_config.thinking_level)

    def test_retry_keeps_minimal_thinking_when_summaries_are_rejected(self):
        requests, events, _ = self.run_loop([
            ValueError("Thought summaries unsupported"),
            [chunk(types.Part(text="Done."))],
        ])
        self.assertEqual(len(requests), 2)
        self.assertIsNone(requests[1]["config"].thinking_config.include_thoughts)
        self.assertEqual(requests[1]["config"].thinking_config.thinking_level,
                         types.ThinkingLevel.MINIMAL)
        self.assertEqual(events, [("chunk", "Done.")])
