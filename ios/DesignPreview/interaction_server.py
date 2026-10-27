"""Synthetic delayed chat stream for navigation UI tests. No database or model calls."""
import json
import time
from http.server import ThreadingHTTPServer
from server import Handler


class InteractionHandler(Handler):
    def do_POST(self):
        if self.path == '/api/ai/chats/900/stop':
            self.rfile.read(int(self.headers.get('Content-Length', 0)))
            self.send_response(204)
            self.end_headers()
            return
        if self.path != '/api/ai/chat':
            return super().do_POST()
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if b'Show a simulated provider error' in body:
            return self.respond({'detail': 'The sample AI service is temporarily unavailable. Please try again.'}, 503)
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        try:
            self.event({'type': 'init', 'chat_id': 900, 'title': 'Navigation test'})
            self.event({'type': 'chunk', 'delta': 'Checking the sample portfolio…'})
            if b'Simulate an interrupted reply' in body:
                return
            time.sleep(10)
            self.event({'type': 'done', 'content': 'Navigation test reply completed once.'})
        except (BrokenPipeError, ConnectionResetError):
            pass

    def event(self, value):
        self.wfile.write(('data: ' + json.dumps(value) + '\n\n').encode())
        self.wfile.flush()


if __name__ == '__main__':
    print('Synthetic delayed chat: http://127.0.0.1:8109', flush=True)
    ThreadingHTTPServer(('127.0.0.1', 8109), InteractionHandler).serve_forever()
