"""Chat transport/lifecycle regressions with isolated data and synthetic faults."""
import json
import os
from unittest.mock import patch

from google.genai import types

from app.database import Chat, ChatMessage, Trade
from app.routers import ai
from app.services import ai_tools
from test_ai_features import AIFeatureFixture, IMAGE, MODEL, USER, model_chunk
from test_ai_agentic import call, reply


class ChatLifecycleTests(AIFeatureFixture):
    def new_chat(self):
        with self.sessions() as db:
            chat = Chat(title="Lifecycle test", user_id=USER)
            db.add(chat)
            db.flush()
            cid = chat.id
            db.add(ChatMessage(chat_id=cid, role="user", content="Explain my portfolio"))
            db.commit()
        return cid

    def run_worker(self, cid, stream):
        run = ai._ChatRun(chat_id=cid, title="Lifecycle test")
        ai._runs[cid] = run
        with patch.object(ai_tools, "run_tool_loop", side_effect=lambda *args: stream(run)):
            ai._generate_run(run, "gemini", "synthetic-key", MODEL,
                             [("user", "Explain my portfolio", None, None)], [], USER)
        events = [json.loads(e[6:]) for e in run.tail() if e.startswith("data: ")]
        self.assertTrue(run._done)
        self.assertNotIn(cid, ai._runs)
        return events

    def test_stop_is_owner_scoped_and_persists_only_streamed_partial_answer(self):
        cid = self.new_chat()

        def stream(run):
            yield "chunk", "Verified partial answer."
            denied = self.client.post(f"/api/ai/chats/{cid}/stop", headers={"Authorization": "Bearer other"})
            self.assertEqual(denied.status_code, 404)
            self.assertFalse(run.cancelled)
            self.assertEqual(self.client.post(f"/api/ai/chats/{cid}/stop").status_code, 204)
            yield "chunk", "THIS MUST NOT APPEAR"

        events = self.run_worker(cid, stream)
        self.assertEqual([e["type"] for e in events], ["init", "status", "chunk", "done"])
        self.assertIn("Verified partial answer.\n\n_(stopped)_", events[-1]["content"])
        self.assertNotIn("THIS MUST NOT APPEAR", json.dumps(events))
        messages = self.client.get(f"/api/ai/chats/{cid}").json()["messages"]
        self.assertEqual(len(messages), 2)
        self.assertEqual(messages[-1]["content"], events[-1]["content"])
        self.assertEqual(self.client.post(f"/api/ai/chats/{cid}/stop").status_code, 204)

    def test_detached_run_survives_disconnected_tail_and_can_replay_complete_buffer(self):
        run = ai._ChatRun(chat_id=123, title="Disconnected test")
        run.emit({"type": "init", "chat_id": 123})
        first_connection = run.tail()
        self.assertIn('"init"', next(first_connection))
        first_connection.close()
        self.assertFalse(run.cancelled)
        run.emit({"type": "chunk", "delta": "Continued after disconnect"})
        run.emit({"type": "done", "content": "Continued after disconnect"})
        run.finish()
        replay = [json.loads(e[6:]) for e in run.tail()]
        self.assertEqual([e["type"] for e in replay], ["init", "chunk", "done"])

    def test_history_rename_delete_and_followup_are_isolated_by_owner(self):
        self.fake_gemini([[reply("Original answer.")]])
        cid = self.chat("Original question", image=IMAGE)[0]["chat_id"]
        other = {"Authorization": "Bearer other"}
        self.assertEqual(self.client.get("/api/ai/chats", headers=other).json(), [])
        self.assertEqual(self.client.get(f"/api/ai/chats/{cid}", headers=other).status_code, 404)
        self.assertEqual(self.client.patch(f"/api/ai/chats/{cid}", headers=other,
                                          json={"title": "Foreign rename"}).status_code, 404)
        self.assertEqual(self.client.delete(f"/api/ai/chats/{cid}", headers=other).status_code, 404)
        denied = self.client.post("/api/ai/chat", data={"message": "Foreign followup", "chat_id": cid},
                                  headers={**other, "X-AI-Key": "synthetic-key"})
        self.assertEqual(denied.status_code, 404)
        renamed = self.client.patch(f"/api/ai/chats/{cid}", json={"title": "  Renamed conversation  "})
        self.assertEqual(renamed.status_code, 200)
        self.assertEqual(renamed.json()["title"], "Renamed conversation")
        self.assertEqual(renamed.json()["message_count"], 2)
        self.assertEqual(self.client.delete(f"/api/ai/chats/{cid}").status_code, 204)
        self.assertEqual(self.client.get(f"/api/ai/chats/{cid}").status_code, 404)
        with self.sessions() as db:
            self.assertEqual(db.query(ChatMessage).filter_by(chat_id=cid).count(), 0)

    def test_rejected_draft_followup_and_history_reload_never_save_trade(self):
        draft = {"ticker": "AAPL", "type": "buy", "shares": .75, "price": 199.5,
                 "market": "US", "date": "2026-10-06"}
        requests = self.fake_gemini([[call("add_trade", draft)], [reply()],
                                     [reply("Draft dismissed. Nothing was saved.")]])
        with self.sessions() as db:
            before = [(t.id, t.shares, t.price) for t in db.query(Trade).order_by(Trade.id)]
        first = self.chat("Prepare this trade for review")
        cid = first[0]["chat_id"]
        self.assertTrue(any(e["type"] == "action" for e in first))
        self.client.get(f"/api/ai/chats/{cid}").raise_for_status()
        rejected = self.chat("Cancel that proposed trade. Do not save it.", chat_id=cid)
        self.assertFalse(any(e["type"] == "action" for e in rejected))
        self.assertIn("Cancel that proposed trade", requests[-1]["contents"][-1].parts[0].text)
        with self.sessions() as db:
            self.assertEqual([(t.id, t.shares, t.price) for t in db.query(Trade).order_by(Trade.id)], before)

    def test_invalid_uploads_are_rejected_before_chat_or_provider_side_effects(self):
        with patch("google.genai.Client") as provider, patch.object(ai, "CHAT_IMAGE_MAX_BYTES", 8):
            cases = [("empty", "", None, 400),
                     ("empty image", "", ("empty.png", b"", "image/png"), 400),
                     ("unsupported", "Read this", ("bad.gif", b"GIF89a", "image/gif"), 400),
                     ("oversized", "Read this", ("big.png", b"x" * 9, "image/png"), 413)]
            for label, message, upload, status in cases:
                with self.subTest(case=label):
                    response = self.client.post("/api/ai/chat", data={"message": message},
                        files={"file": upload} if upload else None, headers={"X-AI-Key": "synthetic-key"})
                    self.assertEqual(response.status_code, status, response.text)
            provider.assert_not_called()
        with self.sessions() as db:
            self.assertEqual(db.query(Chat).count(), 0)
            self.assertEqual(db.query(ChatMessage).count(), 0)

    def test_jpg_mime_is_normalized_for_provider_and_persisted_history(self):
        requests = self.fake_gemini([[model_chunk(types.Part(text="Image accepted."))]])
        response = self.client.post("/api/ai/chat", data={"message": "Read image"},
            files={"file": ("photo.jpg", IMAGE, "image/jpg")}, headers={"X-AI-Key": "synthetic-key"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(requests[0]["contents"][-1].parts[-1].inline_data.mime_type, "image/jpeg")
        with self.sessions() as db:
            self.assertEqual(db.query(ChatMessage).filter_by(role="user").one().image_mime, "image/jpeg")

    def test_chat_uses_server_key_when_header_absent_and_explicit_personal_key_when_present(self):
        def response(*args):
            yield "chunk", "Connection checked."
        with patch.dict(os.environ, {"GOOGLE_AI_API_KEY": "synthetic-server-key"}), \
             patch.object(ai_tools, "run_tool_loop", side_effect=response) as loop:
            for headers, expected in [({}, "synthetic-server-key"),
                                      ({"X-AI-Key": "  synthetic-personal-key  "}, "synthetic-personal-key"),
                                      ({"X-AI-Key": "   "}, "synthetic-server-key")]:
                with self.subTest(mode="personal" if expected.endswith("personal-key") else "included"):
                    result = self.client.post("/api/ai/chat", data={"message": "Check connection"}, headers=headers)
                    self.assertEqual(result.status_code, 200)
                    self.assertEqual(loop.call_args.args[1], expected)
                    self.assertNotIn(expected, result.text)

    def test_missing_server_and_personal_keys_fail_before_persisting_a_chat(self):
        with patch.dict(os.environ, {"GOOGLE_AI_API_KEY": ""}), patch.object(ai_tools, "run_tool_loop") as loop:
            response = self.client.post("/api/ai/chat", data={"message": "Check connection"})
        self.assertEqual(response.status_code, 503)
        loop.assert_not_called()
        with self.sessions() as db:
            self.assertEqual(db.query(Chat).count(), 0)

    def test_unexpected_worker_failure_preserves_partial_reply_without_leaking_secrets(self):
        cid = self.new_chat()
        def stream(run):
            yield "chunk", "Known partial answer."
            raise RuntimeError("database failed: postgresql://user:SYNTHETIC_PRIVATE_PASSWORD@private-host/db")
        with self.assertLogs("app.routers.ai", level="WARNING") as logs:
            events = self.run_worker(cid, stream)
        self.assertEqual(events[-1]["type"], "error")
        self.assertNotIn("SYNTHETIC_PRIVATE_PASSWORD", json.dumps(events))
        self.assertNotIn("private-host", json.dumps(events))
        self.assertNotIn("SYNTHETIC_PRIVATE_PASSWORD", str(logs.output))
        saved = self.client.get(f"/api/ai/chats/{cid}").json()["messages"][-1]["content"]
        self.assertIn("Known partial answer.", saved)
        self.assertIn('"interrupted": true', saved)
        self.assertNotIn("SYNTHETIC_PRIVATE_PASSWORD", saved)

    def test_unexpected_tool_failure_is_recoverable_without_exposing_internal_credentials(self):
        with patch.object(ai_tools, "_execute", side_effect=RuntimeError("SYNTHETIC_PRIVATE_PASSWORD private-db-url")), \
             self.assertLogs("app.services.ai_tools", level="WARNING") as logs:
            result, action = ai_tools.execute("get_holdings", {}, USER)
        self.assertIn("error", result)
        self.assertIsNone(action)
        self.assertNotIn("SYNTHETIC_PRIVATE_PASSWORD", json.dumps(result))
        self.assertNotIn("private-db-url", json.dumps(result))
        self.assertNotIn("SYNTHETIC_PRIVATE_PASSWORD", str(logs.output))
