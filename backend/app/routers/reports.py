"""PDF reports.

``POST`` starts a render and returns immediately; the app polls ``GET``. The
work happens on a background thread because a Document Generation round trip is
seconds, and a request that blocked on it would time out on a mobile network
for no reason.

Everything is scoped to the caller — a report is built from one account's
records, and an id belonging to another account reads as "not found" rather
than revealing that it exists.
"""
from __future__ import annotations

import json
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from ..auth import get_current_user
from ..database import Report, get_db
from ..services import reports

router = APIRouter(prefix="/api/reports", tags=["reports"])


class ReportRequest(BaseModel):
    template: str
    period: str = "ytd"
    params: dict = Field(default_factory=dict)


def _out(row: Report) -> dict:
    body = {
        "report_id": row.id,
        "status": row.status,
        "template": row.template,
        "period": row.period,
        "title": row.title,
        "subtitle": row.subtitle,
        "headline": row.headline,
        "row_count": row.row_count,
        "pages": row.pages,
        "bytes": row.bytes,
        "renderer": row.renderer,
        "fx_rate": row.fx_rate,
        "created_at": row.created_at.isoformat() if row.created_at else None,
        "generated_at": row.generated_at.isoformat() if row.generated_at else None,
        # The app builds its own page-1 thumbnail from the downloaded PDF with
        # PDFKit — native, offline, and one fewer service holding credentials.
        "thumbnail_url": None,
    }
    if row.status == "ready":
        body["url"] = f"/api/reports/{row.id}/file"
    if row.status == "failed":
        body["error"] = row.error
    return body


@router.get("")
def list_reports(db: Session = Depends(get_db), user: str = Depends(get_current_user)):
    rows = (db.query(Report)
            .filter(Report.user_id == user)
            .order_by(Report.created_at.desc())
            .limit(50)
            .all())
    return {"reports": [_out(r) for r in rows],
            "templates": reports.TEMPLATES,
            "renderer": "adobe" if reports.adobe_configured() else "local"}


@router.post("")
def create_report(payload: ReportRequest,
                  db: Session = Depends(get_db),
                  user: str = Depends(get_current_user)):
    if payload.template not in reports.TEMPLATE_IDS:
        raise HTTPException(400, f"Unknown template {payload.template!r}")

    version = reports.data_version(db, user)
    key = reports.cache_key(payload.template, payload.period, payload.params, version)

    # A repeat request over unchanged records returns the existing report and
    # burns no Document Transaction — the whole reason the key folds in a data
    # version. A failed one is not reused; that would cache the failure.
    cached = (db.query(Report)
              .filter(Report.user_id == user, Report.cache_key == key,
                      Report.status != "failed")
              .order_by(Report.created_at.desc())
              .first())
    if cached is not None and (cached.status != "ready"
                               or reports.file_path(cached.id).exists()):
        return {**_out(cached), "cached": True}

    definition = reports.template_def(payload.template)
    _start, _end, label = reports.resolve_period(payload.period)
    row = Report(
        id=reports.new_id(), user_id=user, template=payload.template,
        period=payload.period, params=json.dumps(payload.params or {}),
        cache_key=key, status="pending",
        title=definition["name"], subtitle=f"{label} · TWD base",
        created_at=datetime.utcnow())
    db.add(row)
    db.commit()

    reports.start(row.id, user, payload.template, payload.period, payload.params)
    reports.evict_old()
    return {**_out(row), "cached": False}


@router.get("/{report_id}")
def get_report(report_id: str, db: Session = Depends(get_db),
               user: str = Depends(get_current_user)):
    row = db.get(Report, report_id)
    if row is None or row.user_id != user:
        raise HTTPException(404, "No such report")
    return _out(row)


@router.get("/{report_id}/file")
def get_report_file(report_id: str, db: Session = Depends(get_db),
                    user: str = Depends(get_current_user)):
    row = db.get(Report, report_id)
    if row is None or row.user_id != user:
        raise HTTPException(404, "No such report")
    if row.status != "ready":
        raise HTTPException(409, f"Report is {row.status}")
    path = reports.file_path(report_id)
    if not path.exists():
        raise HTTPException(410, "Report file has been evicted")
    return FileResponse(path, media_type="application/pdf",
                        headers={"Content-Disposition":
                                 f'inline; filename="{report_id}.pdf"'})
