"""Read-only, synthetic UI preview API. No database, credentials or market requests.
Run: python3 ios/DesignPreview/server.py (localhost:8099).
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
from datetime import date, timedelta
import json
import math

END = date(2026, 10, 27)
DATES = [(END - timedelta(days=(59-i)*5)).isoformat() for i in range(60)]
NAMES = {'2330': '台積電', '2382': '廣達', '0050': '元大台灣50', 'AAPL': 'Apple', 'NVDA': 'NVIDIA', 'VOO': 'Vanguard S&P 500'}
HOLDINGS = []
for ticker, shares, cost, price, prev in [('2330', 230, 910, 1130, 1115), ('2382', 400, 240, 285, 281), ('0050', 2000, 53, 62, 61.8), ('AAPL', 35, 190, 237, 233), ('NVDA', 80, 98, 142, 140), ('VOO', 25, 470, 535, 532)]:
    market = 'TW' if ticker.isdigit() else 'US'
    value, basis = shares*price, shares*cost
    exit_cost = value*.004425 if market == 'TW' else 0
    pl = value-basis-exit_cost
    HOLDINGS.append(dict(ticker=ticker,name=NAMES[ticker],market=market,currency='TWD' if market=='TW' else 'USD',shares=shares,avg_cost=cost,current_price=price,market_value=value,cost_basis=basis,exit_cost=exit_cost,unrealized_pl=pl,unrealized_pl_pct=pl/basis*100,today_change=(price-prev)*shares,today_change_pct=(price/prev-1)*100))
TRADES = [dict(id=i+1,type='buy',ticker=h['ticker'],shares=h['shares'],price=h['avg_cost'],trade_date='2026-08-12',fee=0,notes=None,market=h['market'],created_at='2026-08-12T12:00:00',status='open') for i,h in enumerate(HOLDINGS)]
DIVIDENDS = [dict(id=i+1,ticker=t,amount=a,currency='TWD' if t.isdigit() else 'USD',market='TW' if t.isdigit() else 'US',pay_date=d,notes=None,created_at=d+'T12:00:00') for i,(t,a,d) in enumerate([('2330',1380,'2026-10-09'),('0050',1800,'2026-08-14'),('AAPL',9.1,'2026-08-13'),('VOO',45.2,'2026-09-30')])]
SUMMARIES = []
for market in ['TW','US']:
    hs=[h for h in HOLDINGS if h['market']==market]
    value=sum(h['market_value'] for h in hs);cost=sum(h['cost_basis'] for h in hs);pl=sum(h['unrealized_pl'] for h in hs);today=sum(h['today_change'] for h in hs)
    dividends=sum(d['amount'] for d in DIVIDENDS if d['market']==market)
    SUMMARIES.append(dict(currency='TWD' if market=='TW' else 'USD',total_value=value,total_cost=cost,total_pl=pl,total_pl_pct=pl/cost*100,today_pl=today,today_pl_pct=today/(value-today)*100,realized_pl=0,dividends=dividends,total_earned=dividends,year_earned=dividends,year=2026,holdings_count=len(hs)))
FX = 31.8
TOTAL = SUMMARIES[0]['total_value'] + SUMMARIES[1]['total_value']*FX
OVERVIEW=dict(tw=SUMMARIES[0],us=SUMMARIES[1],fx=dict(usd_twd=FX,asof=END.isoformat()),combined=dict(twd=TOTAL,usd=TOTAL/FX))

def history(total):
    return [dict(date=d,total=round(total*(.77+.23*i/59+.018*math.sin(i*.7)),2)) for i,d in enumerate(DATES)]

def detail(ticker):
    h=next((h for h in HOLDINGS if h['ticker']==ticker),HOLDINGS[0]);price=h['current_price']
    return dict(ticker=ticker,symbol=ticker,name=h['name'],live=dict(price=price,previous_close=price*.99,today_change=price*.01,today_change_pct=1,volume=32540000),fundamentals=dict(currency=h['currency'],pe=25.4,eps=44.5,market_cap=29000000000000,fifty_two_week_high=price*1.1,fifty_two_week_low=price*.65,dividend_yield=1.8,sector='Technology'),position=dict(shares=h['shares'],avg_cost=h['avg_cost'],cost_basis=h['cost_basis'],market_value=h['market_value'],exit_cost=h['exit_cost'],unrealized_pl=h['unrealized_pl'],unrealized_pl_pct=h['unrealized_pl_pct'],realized_pl=0,dividends_received=1380,total_return=h['unrealized_pl']+1380,total_return_pct=h['unrealized_pl_pct'],first_buy_date='2026-08-12',holding_days=76,trade_count=1,fees_paid=0),history=[dict(date=p['date'],close=p['total']) for p in history(price)],taiex_history=[],trades=[],dividends=[],yield_on_cost=2.1,monthly_revenue=[],quarterly_financials=[])

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_POST(self): self.respond({'detail':'Preview is read-only'},405)
    do_PUT=do_POST
    do_DELETE=do_POST
    def respond(self,body,status=200):
        data=json.dumps(body).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
    def do_GET(self):
        url=urlparse(self.path);path=url.path;query=parse_qs(url.query);market=query.get('market',['TW'])[0];si=0 if market=='TW' else 1
        values={
          '/api/health':{'status':'ok'},'/api/trades':TRADES,'/api/dividends':DIVIDENDS,
          '/api/portfolio/holdings':HOLDINGS,'/api/portfolio/summary':SUMMARIES,'/api/portfolio/overview':OVERVIEW,'/api/portfolio/names':NAMES,
          '/api/markets':[dict(code=m,name=m,currency='TWD' if m=='TW' else 'USD',timezone='Asia/Taipei' if m=='TW' else 'America/New_York',open_minute=540 if m=='TW' else 570,close_minute=810 if m=='TW' else 960,holidays=[END.isoformat()]) for m in ['TW','US']],
          '/api/portfolio/earnings-history':{s['currency']:[dict(date=d,realized=0,dividends=s['dividends']*i/59,total=s['dividends']*i/59) for i,d in enumerate(DATES)] for s in SUMMARIES},
          '/api/portfolio/value-history':history(SUMMARIES[si]['total_value']),
          '/api/portfolio/benchmark':dict(benchmarks={'TW':'^TWII','US':'^GSPC'},names={'TW':'TAIEX','US':'S&P 500'}),
          '/api/portfolio/performance':dict(market=market,currency='TWD' if market=='TW' else 'USD',period=query.get('period',['1y'])[0],twr_pct=23.1,twr_annualized_pct=23.1,xirr_pct=25.4,period_pl=SUMMARIES[si]['total_pl'],portfolio_series=[dict(date=p['date'],pct=(p['total']-1)*100) for p in history(1.23)],benchmark=dict(symbol='^TWII' if market=='TW' else '^GSPC',name='TAIEX' if market=='TW' else 'S&P 500',return_pct=16.5,series=[dict(date=p['date'],pct=(p['total']-1)*100) for p in history(1.165)]),monthly=[dict(month=f'2026-{m:02d}',pl=(m-4)*1250,return_pct=m-4) for m in range(5,11)]),
          '/api/indices':dict(indices=[dict(symbol='^TWII',name='TAIEX',market='TW',price=24560,change=198,change_pct=.81),dict(symbol='^GSPC',name='S&P 500',market='US',price=5892,change=24,change_pct=.41)]),
          '/api/dividends/calendar':dict(projected_annual=[],months=[],upcoming=[dict(ticker='2330',market='TW',currency='TWD',ex_date='2026-12-12',amount=1380,per_share=6),dict(ticker='VOO',market='US',currency='USD',ex_date='2026-12-19',amount=45.2,per_share=1.808)]),
          '/api/ai/status':dict(configured=True,model='gemini-3.5-flash-lite'),'/api/ai/chats':[],
          '/api/quotes/sources':dict(mis=dict(available=False,realtime=False),yahoo=dict(available=False,realtime=False)),
          '/api/reports':[],
        }
        if path.startswith('/api/stock/') and path.endswith('/detail'): return self.respond(detail(path.split('/')[3]))
        self.respond(values[path]) if path in values else self.respond({'detail':'Preview endpoint unavailable'},404)

if __name__=='__main__':
    print('Synthetic preview API: http://127.0.0.1:8099',flush=True)
    ThreadingHTTPServer(('127.0.0.1',8099),Handler).serve_forever()
