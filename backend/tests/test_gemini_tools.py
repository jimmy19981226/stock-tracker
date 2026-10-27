"""Gemini streaming/tool protocol regressions, without live API or DB calls."""
from copy import deepcopy
from types import SimpleNamespace
from threading import Barrier
from unittest import TestCase
from unittest.mock import patch

from google.genai import errors, types

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

    def test_numeric_answer_is_checked_before_it_is_sent(self):
        requests, events, execute = self.run_loop([
            [chunk(types.Part(function_call=types.FunctionCall(name="get_portfolio_summary", args={}, id="read")))],
            [chunk(types.Part(text="Your profit is 999999."))],
            [chunk(types.Part(function_call=types.FunctionCall(name="answer_with_data", args={
                "format": "json", "facts": [{"name": "profit", "source_id": 1, "path": "value"}]}, id="answer")))],
        ])
        self.assertEqual([e for e in events if e[0] == "chunk"], [("chunk", '{"profit": 1234.56}')])
        self.assertEqual(requests[2]["config"].tool_config.function_calling_config.allowed_function_names,
                         ["answer_with_data"])
        execute.assert_called_once()

    def test_invalid_fact_reference_can_be_corrected(self):
        requests, events, execute = self.run_loop([
            [chunk(types.Part(function_call=types.FunctionCall(name="get_holdings", args={}, id="read")))],
            [chunk(types.Part(function_call=types.FunctionCall(name="answer_with_data", args={
                "facts": [{"name": "shares", "source_id": 999, "path": "value"}]}, id="bad")))],
            [chunk(types.Part(function_call=types.FunctionCall(name="answer_with_data", args={
                "format": "json", "facts": [{"name": "shares", "source_id": 1, "path": "value"}]}, id="good")))],
        ])
        self.assertIn("Unknown source_id", requests[2]["contents"][-1].parts[0].function_response.response["result"]["error"])
        self.assertEqual(events[-1], ("chunk", '{"shares": 1234.56}'))
        execute.assert_called_once()

    def test_round_limit_returns_available_data_and_reuses_duplicate_reads(self):
        _, events, execute = self.run_loop([
            [chunk(types.Part(function_call=types.FunctionCall(name="get_holdings", args={}, id=f"read-{i}")))]
            for i in range(ai_tools.MAX_TOOL_ROUNDS)
        ])
        self.assertIn("analysis limit", events[-1][1])
        self.assertIn("1,234.56", events[-1][1])
        execute.assert_called_once()

    def test_network_failure_returns_available_data(self):
        _, events, _ = self.run_loop([
            [chunk(types.Part(function_call=types.FunctionCall(name="get_holdings", args={}, id="read")))],
            RuntimeError("Network disconnected"),
        ])
        self.assertIn("could not finish", events[-1][1])
        self.assertIn("1,234.56", events[-1][1])

    def test_empty_model_response_still_has_a_useful_answer(self):
        _, events, _ = self.run_loop([[]])
        self.assertIn("Please try again", events[-1][1])

    def test_provider_errors_have_actionable_messages_without_leaking_provider_details(self):
        class ProviderError(Exception):
            def __init__(self, code):
                self.code = code
                super().__init__("private provider diagnostic")

        for code, expected in [(503, "temporarily unavailable"), (429, "usage limit"),
                               (401, "API key and model access"), (403, "API key and model access"),
                               (400, "try a new chat; if it continues, check the AI configuration")]:
            with self.subTest(code=code):
                _, events, _ = self.run_loop([ProviderError(code)])
                self.assertIn(expected, events[-1][1])
                self.assertNotIn("private provider diagnostic", events[-1][1])

    def test_rejected_personal_keys_are_classified_without_exposing_sdk_diagnostics(self):
        secret = "synthetic-private-api-key"
        for code, reason in [(400, "API_KEY_INVALID"), (400, "API_KEY_EXPIRED"),
                             (403, "API_KEY_SERVICE_BLOCKED"), (403, "API_KEY_HTTP_REFERRER_BLOCKED"),
                             (403, "API_KEY_IP_ADDRESS_BLOCKED"), (403, "API_KEY_IOS_APP_BLOCKED"),
                             (401, "API_KEY_API_TARGET_BLOCKED")]:
            with self.subTest(code=code, reason=reason):
                failure = errors.ClientError(code, {"error": {
                    "code": code, "status": "INVALID_ARGUMENT" if code == 400 else "PERMISSION_DENIED",
                    "message": f"Credential rejected for {secret}",
                    "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": reason,
                                 "metadata": {"apiKey": secret, "consumer": "private-project", "referrer": "private-referrer"}}],
                }})
                self.assertEqual(ai_tools._gemini_error_category(failure), "invalid_api_key")
                with self.assertLogs("app.services.ai_tools", level="WARNING") as captured:
                    requests, events, executed = self.run_loop([failure])
                self.assertEqual(len(requests), 1)
                executed.assert_not_called()
                self.assertIn("Included AI", events[-1][1])
                self.assertIn("Settings", events[-1][1])
                safe_output = " ".join(captured.output) + " " + str(events)
                for private in (secret, "private-project", "private-referrer", "Credential rejected for"):
                    self.assertNotIn(private, safe_output)

    def test_message_only_invalid_key_error_has_the_same_safe_recovery_guidance(self):
        failure = errors.ClientError(400, {"error": {"code": 400, "status": "INVALID_ARGUMENT",
            "message": "API key not valid. Please pass a valid API key. PRIVATE_TEST_SECRET"}})
        self.assertEqual(ai_tools._gemini_error_category(failure), "invalid_api_key")
        with self.assertLogs("app.services.ai_tools", level="WARNING") as captured:
            _, events, _ = self.run_loop([failure])
        self.assertIn("replace your personal Gemini key", events[-1][1])
        self.assertNotIn("PRIVATE_TEST_SECRET", str(events) + str(captured.output))

    def test_unrelated_bad_request_is_not_misdiagnosed_as_an_invalid_key(self):
        failure = errors.ClientError(400, {"error": {"code": 400, "status": "INVALID_ARGUMENT",
            "message": "candidate_count is unsupported; api_key=PRIVATE_TEST_SECRET",
            "details": [{"reason": "INVALID_ARGUMENT", "metadata": {"request": "private-input"}}]}})
        self.assertEqual(ai_tools._gemini_error_category(failure), "invalid_request")
        with self.assertLogs("app.services.ai_tools", level="WARNING") as captured:
            _, events, _ = self.run_loop([failure])
        self.assertIn("try a new chat", events[-1][1])
        self.assertNotIn("Included AI", events[-1][1])
        for private in ("PRIVATE_TEST_SECRET", "candidate_count", "private-input"):
            self.assertNotIn(private, str(events) + str(captured.output))

    def test_credential_rejection_after_tool_read_preserves_only_known_facts(self):
        failure = errors.ClientError(400, {"error": {"code": 400, "message": "API_KEY_INVALID PRIVATE_TEST_SECRET"}})
        with self.assertLogs("app.services.ai_tools", level="WARNING") as captured:
            requests, events, executed = self.run_loop([
                [chunk(types.Part(function_call=types.FunctionCall(name="get_holdings", args={}, id="read")))],
                failure,
            ])
        self.assertEqual(len(requests), 2)
        executed.assert_called_once()
        self.assertIn("Included AI", events[-1][1])
        self.assertIn("1,234.56", events[-1][1])
        self.assertNotIn("PRIVATE_TEST_SECRET", str(events) + str(captured.output))

    def test_temporary_provider_failure_preserves_checked_data_and_does_not_retry_forever(self):
        class Unavailable(Exception):
            code = 503
        requests, events, execute = self.run_loop([
            [chunk(types.Part(function_call=types.FunctionCall(name="get_holdings", args={}, id="read")))],
            Unavailable("unavailable"),
        ])
        self.assertEqual(len(requests), 2)
        execute.assert_called_once()
        self.assertIn("temporarily unavailable", events[-1][1])
        self.assertIn("1,234.56", events[-1][1])

    def test_independent_reads_run_concurrently(self):
        barrier = Barrier(2)
        responses = iter([
            [chunk(*[types.Part(function_call=types.FunctionCall(name=name, args={}, id=name))
                     for name in ("get_trades", "get_dividends")])],
            [chunk(types.Part(text="Records checked."))],
        ])
        client = SimpleNamespace(models=SimpleNamespace(generate_content_stream=lambda **_: iter(next(responses))))

        def execute(*_):
            barrier.wait(timeout=3)
            return {"count": 1}, None

        with patch("google.genai.Client", return_value=client), patch.object(ai_tools, "execute", side_effect=execute):
            events = list(ai_tools._gemini_loop("test", MODEL, "test", [("user", "check", None, None)], "user"))
        self.assertEqual(events[-1], ("chunk", "Records checked."))

    def test_fact_array_indexes_match_the_sampled_data_visible_to_the_model(self):
        points = [{"date": f"day-{i}", "total": i} for i in range(100)]
        with patch.object(ai_tools, "_RESULT_CAPS", {"get_value_history": 600}):
            requests, events, _ = self.run_loop([
                [chunk(types.Part(function_call=types.FunctionCall(name="get_value_history", args={}, id="read")))],
                [chunk(types.Part(function_call=types.FunctionCall(name="answer_with_data", args={
                    "format": "json", "facts": [{"name": "point", "source_id": 1, "path": "points.1.total"}]}, id="answer")))],
            ], tool_result=({"points": points}, None))
        shown = requests[1]["contents"][-1].parts[0].function_response.response["result"]
        self.assertTrue(shown["_sampling"]["sampled"])
        self.assertEqual(shown["points"][-1]["total"], 99)
        self.assertGreater(shown["points"][1]["total"], 1)
        self.assertEqual(events[-1], ("chunk", '{"point": ' + str(shown["points"][1]["total"]) + '}'))
