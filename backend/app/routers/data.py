from datetime import datetime

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from fastapi.responses import Response
from sqlalchemy.orm import Session

from ..database import Dividend, Metadata, Trade, get_db
from ..services import csv_io

router = APIRouter(prefix="/api/data", tags=["data"])

LAST_EXPORT_KEY = "last_export"


def _record_last_export(db: Session) -> None:
    now_iso = datetime.utcnow().isoformat()
    row = db.query(Metadata).filter(Metadata.key == LAST_EXPORT_KEY).first()
    if row:
        row.value = now_iso
    else:
        db.add(Metadata(key=LAST_EXPORT_KEY, value=now_iso))
    db.commit()


@router.get("/export")
def export_portfolio(db: Session = Depends(get_db)):
    trades = (
        db.query(Trade)
        .order_by(Trade.trade_date.desc(), Trade.id.desc())
        .all()
    )
    dividends = (
        db.query(Dividend)
        .order_by(Dividend.pay_date.desc(), Dividend.id.desc())
        .all()
    )
    csv_text = csv_io.portfolio_to_csv(trades, dividends)
    _record_last_export(db)
    return Response(
        content=csv_text,
        media_type="text/csv",
        headers={"Content-Disposition": 'attachment; filename="portfolio.csv"'},
    )


@router.post("/import")
async def import_portfolio(
    file: UploadFile = File(...), db: Session = Depends(get_db)
):
    raw = await file.read()
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        raise HTTPException(status_code=400, detail="File must be UTF-8 encoded")
    try:
        trades, dividends = csv_io.parse_portfolio_csv(text)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    csv_io.insert_trades(db, trades)
    csv_io.insert_dividends(db, dividends)
    return {"trades": len(trades), "dividends": len(dividends)}


@router.get("/last-export")
def get_last_export(db: Session = Depends(get_db)):
    row = db.query(Metadata).filter(Metadata.key == LAST_EXPORT_KEY).first()
    return {"last_export": row.value if row else None}
