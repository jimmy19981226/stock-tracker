"""Broker screenshot import boundaries; provider transport is synthetic."""
import json
import os
import threading
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace
from unittest.mock import patch

from app.database import Dividend, Trade
from app.routers import ai
from test_ai_features import AIFeatureFixture, IMAGE


class ScreenshotImportTests(AIFeatureFixture):
    def setUp(self):
        super().setUp()
        self.stack.enter_context(patch.dict(os.environ, {"GOOGLE_AI_API_KEY": "synthetic-import-key"}))
        self.provider = self.stack.enter_context(patch("google.genai.Client"))
        self.generate = self.provider.return_value.models.generate_content

    def upload(self, raw=IMAGE, mime="image/png", instructions=""):
        return self.client.post("/api/ai/parse-records", files={"file": ("statement.png", raw, mime)},
                                data={"instructions": instructions})

    def test_valid_extraction_preserves_fields_and_is_only_a_preview(self):
        payload = {"trades": [{"ticker": "2330", "type": "buy", "shares": 1000,
                               "price": 1065.5, "date": "2026-10-06", "fee": 1518.34,
                               "notes": "Shares converted from one lot"}],
                   "dividends": [{"ticker": "2330", "amount": 1234.56,
                                  "date": "2026-10-01", "notes": "Total cash payment"}],
                   "notes": "Review before saving"}
        self.generate.return_value = SimpleNamespace(text=json.dumps(payload))
        with self.sessions() as db:
            before = (db.query(Trade).count(), db.query(Dividend).count())
        response = self.upload(instructions="Amounts shown are TWD.")
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json(), payload)
        request = self.generate.call_args.kwargs
        self.assertEqual(request["contents"][0].parts[-1].inline_data.data, IMAGE)
        self.assertIn("Amounts shown are TWD.", request["contents"][0].parts[0].text)
        self.assertEqual(request["config"].response_mime_type, "application/json")
        with self.sessions() as db:
            self.assertEqual((db.query(Trade).count(), db.query(Dividend).count()), before)

    def test_invalid_uploads_never_call_provider(self):
        with patch.object(ai, "PARSE_MAX_BYTES", 8):
            for raw, mime, expected in [(b"", "image/png", 400), (b"GIF", "image/gif", 400),
                                        (b"x" * 9, "image/png", 413)]:
                with self.subTest(mime=mime, length=len(raw)):
                    self.assertEqual(self.upload(raw, mime).status_code, expected)
        self.generate.assert_not_called()

    def test_health_request_completes_while_screenshot_provider_is_still_blocked(self):
        # Mount the real lightweight health handler on the isolated app; do not
        # start production lifespan, background quotes, or production storage.
        from app.main import health
        self.client.app.add_api_route("/api/health", health, methods=["GET"])
        provider_started = threading.Event()
        release_provider = threading.Event()

        def slow_provider(**kwargs):
            provider_started.set()
            if not release_provider.wait(timeout=10):
                raise TimeoutError("Test did not release synthetic provider")
            return SimpleNamespace(text='{"trades":[],"dividends":[]}')

        self.generate.side_effect = slow_provider
        with ThreadPoolExecutor(max_workers=2) as requests:
            parsing = requests.submit(self.upload)
            try:
                self.assertTrue(provider_started.wait(timeout=3), "Screenshot request never reached provider")
                health_request = requests.submit(self.client.get, "/api/health")
                response = health_request.result(timeout=2)
                self.assertEqual(response.status_code, 200)
                self.assertEqual(response.json(), {"status": "ok"})
                self.assertFalse(release_provider.is_set())
                self.assertFalse(parsing.done(), "Health must complete before provider is released")
            finally:
                release_provider.set()
            self.assertEqual(parsing.result(timeout=3).status_code, 200)

    def test_empty_or_malformed_provider_output_returns_retryable_validation_error(self):
        for text in ("", "not-json", "[]", "null", '{"trades":"not rows","dividends":[]}',
                     '{"trades":[],"dividends":[],"notes":{}}', '{"trades":[null],"dividends":[]}'):
            with self.subTest(output=text):
                self.generate.return_value = SimpleNamespace(text=text)
                response = self.upload()
                self.assertEqual(response.status_code, 422, response.text)

    def test_invalid_extracted_records_never_become_confirmable_drafts(self):
        valid = {"ticker": "2330", "type": "buy", "shares": 100, "price": 1000,
                 "date": "2026-10-06"}
        for changed in ({"shares": -1}, {"shares": True}, {"price": "Infinity"}, {"price": float("inf")},
                        {"fee": False}, {"fee": -1}, {"type": "transfer"},
                        {"date": "2026-99-99"}, {"date": 0}, {"ticker": " "}):
            with self.subTest(changed=changed):
                self.generate.return_value = SimpleNamespace(text=json.dumps(
                    {"trades": [{**valid, **changed}], "dividends": []}))
                response = self.upload()
                self.assertEqual(response.status_code, 422, response.text)
        self.generate.return_value = SimpleNamespace(text=json.dumps(
            {"trades": [], "dividends": [{"ticker": "2330", "amount": -5, "date": "2026-10-06"}]}))
        self.assertEqual(self.upload().status_code, 422)

    def test_provider_import_failure_has_safe_message_without_secret_diagnostic(self):
        self.generate.side_effect = RuntimeError("SYNTHETIC_PRIVATE_API_KEY private-provider-url")
        with self.assertLogs("app.routers.ai", level="WARNING") as logs:
            response = self.upload()
        self.assertEqual(response.status_code, 502)
        self.assertNotIn("SYNTHETIC_PRIVATE_API_KEY", response.text)
        self.assertNotIn("private-provider-url", response.text)
        self.assertNotIn("SYNTHETIC_PRIVATE_API_KEY", str(logs.output))
