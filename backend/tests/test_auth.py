"""Authentication regressions with no Google, market-feed, or database calls."""
import os
from unittest import TestCase
from unittest.mock import patch

from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

from app.auth import get_current_user
from app.routers import webauth


class WebAuthTests(TestCase):
    def setUp(self):
        app = FastAPI()
        app.include_router(webauth.router)
        self.client = TestClient(app)
        self.addCleanup(self.client.close)
        env = patch.dict(os.environ, {"WEB_DASHBOARD_PASSWORD": "portfolio-test-password"})
        env.start()
        self.addCleanup(env.stop)

    def test_correct_password_mints_valid_token(self):
        response = self.client.post('/api/web/login', json={"password": "portfolio-test-password"})
        self.assertEqual(response.status_code, 200)
        self.assertTrue(webauth._token_valid(response.json()['token']))

    def test_unicode_passwords_work_and_wrong_unicode_input_is_unauthorized(self):
        with patch.dict(os.environ, {"WEB_DASHBOARD_PASSWORD": "投資組合🔒"}):
            response = self.client.post('/api/web/login', json={"password": "投資組合🔒"})
            self.assertEqual(response.status_code, 200)
            self.assertTrue(webauth._token_valid(response.json()['token']))
            self.assertEqual(self.client.post('/api/web/login', json={"password": "錯誤"}).status_code, 401)

    def test_expiry_tampering_and_password_rotation_revoke_tokens(self):
        with patch.object(webauth.time, 'time', return_value=1000):
            token, ttl = webauth._mint_token()
            self.assertTrue(webauth._token_valid(token))
            self.assertFalse(webauth._token_valid('999999.' + token.split('.')[1]))
            with patch.dict(os.environ, {"WEB_DASHBOARD_PASSWORD": "rotated"}):
                self.assertFalse(webauth._token_valid(token))
        with patch.object(webauth.time, 'time', return_value=1000 + ttl):
            self.assertFalse(webauth._token_valid(token))

    def test_malformed_tokens_fail_closed_without_exceptions(self):
        for token in ('', None, 'abc', '１２３.' + 'a' * 64, '123.🔒', '1' * 10000 + '.a'):
            with self.subTest(token=str(token)[:20]):
                self.assertFalse(webauth._token_valid(token))

    def test_dashboard_disabled_without_password(self):
        with patch.dict(os.environ, {"WEB_DASHBOARD_PASSWORD": ""}):
            self.assertEqual(self.client.post('/api/web/login', json={"password": ""}).status_code, 503)


class MobileAuthTests(TestCase):
    def test_absent_header_preserves_guest_scope(self):
        self.assertEqual(get_current_user(None), 'legacy')

    def test_malformed_credentials_cannot_downgrade_to_guest(self):
        for header in ('', 'Basic example', 'Bearer', 'Bearer ', 'Token abc'):
            with self.subTest(header=header), self.assertRaises(HTTPException) as error:
                get_current_user(header)
            self.assertEqual(error.exception.status_code, 401)

    def test_valid_google_user_is_preserved(self):
        with patch('app.auth._verify_google_token', return_value='google:example'), \
             patch('app.auth._maybe_adopt_legacy') as adopt:
            self.assertEqual(get_current_user('Bearer token'), 'google:example')
            adopt.assert_called_once_with('google:example')
