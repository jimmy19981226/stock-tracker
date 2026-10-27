"""Synthetic index failure/retry API for MarketTickerTests; no external services.

Run alongside server.py. Restart this process before each test-suite run.
The /empty and /error base URLs return their failure once, then a valid chart.
"""
from collections import Counter
from http.server import ThreadingHTTPServer
from threading import Lock
from urllib.parse import unquote, urlparse

from server import Handler, detail


class IndexPreviewHandler(Handler):
    attempts = Counter()
    lock = Lock()

    def do_GET(self):
        scenario, _, remainder = self.path.lstrip('/').partition('/')
        if scenario not in {'empty', 'error'}:
            return self.respond({'detail': 'Unknown synthetic scenario'}, 404)
        self.path = '/' + remainder
        path = unquote(urlparse(self.path).path)
        if path == '/api/indices':
            return self.respond({'indices': [dict(symbol='^TWOII', name='Taiwan OTC', market='TW',
                                                 price=None, change=None, change_pct=None)]})
        if path == '/api/stock/^TWOII/detail':
            with self.lock:
                self.attempts[scenario] += 1
                attempt = self.attempts[scenario]
            if attempt == 1 and scenario == 'error':
                return self.respond({'detail': 'Synthetic index history outage'}, 503)
            result = detail('2330')
            result.update(ticker='^TWOII', symbol='^TWOII', name='Taiwan OTC')
            if attempt == 1:
                result['history'] = []
            return self.respond(result)
        super().do_GET()


if __name__ == '__main__':
    print('Synthetic index retry API: http://127.0.0.1:8111/{empty,error}', flush=True)
    ThreadingHTTPServer(('127.0.0.1', 8111), IndexPreviewHandler).serve_forever()
