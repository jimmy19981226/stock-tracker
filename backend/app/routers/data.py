from datetime import datetime
from typing import Literal

from fastapi import APIRouter, Depends, File, HTTPException, Query, UploadFile
from fastapi.responses import Response
from sqlalchemy.orm import Session

from ..auth import get_current_user
from ..database import Dividend, Metadata, Trade, get_db
from ..services import xlsx_io

router = APIRouter(prefix="/api/data", tags=["data"])

LAST_EXPORT_KEY = "last_export"
XLSX_MEDIA_TYPE = (
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
)
# Cap the import upload so a huge workbook can't exhaust memory.
IMPORT_MAX_BYTES = 10 * 1024 * 1024  # 10 MB


def _record_last_export(db: Session) -> None:
    now_iso = datetime.utcnow().isoformat()
    row = db.query(Metadata).filter(Metadata.key == LAST_EXPORT_KEY).first()
    if row:
        row.value = now_iso
    else:
        db.add(Metadata(key=LAST_EXPORT_KEY, value=now_iso))
    db.commit()


@router.get("/export")
def export_portfolio(db: Session = Depends(get_db), user: str = Depends(get_current_user)):
    trades = (
        db.query(Trade)
        .filter(Trade.user_id == user)
        .order_by(Trade.trade_date.desc(), Trade.id.desc())
        .all()
    )
    dividends = (
        db.query(Dividend)
        .filter(Dividend.user_id == user)
        .order_by(Dividend.pay_date.desc(), Dividend.id.desc())
        .all()
    )
    xlsx_bytes = xlsx_io.portfolio_to_xlsx(trades, dividends)
    _record_last_export(db)
    return Response(
        content=xlsx_bytes,
        media_type=XLSX_MEDIA_TYPE,
        headers={"Content-Disposition": 'attachment; filename="portfolio.xlsx"'},
    )


@router.post("/import")
async def import_portfolio(
    file: UploadFile = File(...),
    mode: Literal["append", "replace"] = Query("append"),
    db: Session = Depends(get_db),
    user: str = Depends(get_current_user),
):
    """Import a portfolio Excel workbook.

    - ``mode=append`` (default): adds rows to existing data
    - ``mode=replace``: deletes all existing trades + dividends FIRST,
      then imports the file. Atomic: parsing happens before any
      destructive change, and the whole operation commits once.
    """
    raw = await file.read()
    if len(raw) > IMPORT_MAX_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"File too large ({len(raw) / 1e6:.1f} MB). Max "
            f"{IMPORT_MAX_BYTES // (1024 * 1024)} MB.",
        )
    try:
        trades, dividends = xlsx_io.parse_portfolio_xlsx(raw)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    deleted_trades = 0
    deleted_dividends = 0
    try:
        if mode == "replace":
            deleted_trades = (
                db.query(Trade).filter(Trade.user_id == user).delete(synchronize_session=False)
            )
            deleted_dividends = (
                db.query(Dividend).filter(Dividend.user_id == user).delete(synchronize_session=False)
            )

        for t in trades:
            t.user_id = user
            db.add(t)
        for d in dividends:
            d.user_id = user
            db.add(d)
        db.commit()
    except Exception as exc:
        # Roll back so a failed import never leaves the deletes half-applied.
        db.rollback()
        raise HTTPException(status_code=500, detail=f"Import failed: {exc}") from exc

    return {
        "mode": mode,
        "trades": len(trades),
        "dividends": len(dividends),
        "deleted_trades": deleted_trades,
        "deleted_dividends": deleted_dividends,
    }


@router.get("/last-export")
def get_last_export(db: Session = Depends(get_db)):
    row = db.query(Metadata).filter(Metadata.key == LAST_EXPORT_KEY).first()
    return {"last_export": row.value if row else None}
