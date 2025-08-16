import os, json, logging
from typing import Any, Dict, List, Optional
from datetime import datetime, timedelta
from ..http_client import client, retry_policy

log = logging.getLogger("reservation_from_availability")

# ---------- helpers for allMotels shape ----------
def _items(body: Dict[str, Any]) -> List[Dict[str, Any]]:
    try:
        data = body["response"]["data"]
        if isinstance(data, dict):
            inner = data.get("data")
            if isinstance(inner, list):
                return inner
        return data if isinstance(data, list) else []
    except Exception:
        return []

def _pagination(body: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    try:
        data = body["response"]["data"]
        return data.get("pagination") if isinstance(data, dict) else None
    except Exception:
        return None

def _bool(x) -> bool:
    if isinstance(x, bool): return x
    if isinstance(x, str): return x.lower() in ("1","true","yes")
    return bool(x)

# ---------- API calls ----------
@retry_policy()
def _fetch_availability(page: int, per_page: int, page_param: str, per_page_param: str) -> Dict[str, Any]:
    params = {page_param: page, per_page_param: per_page}
    with client() as c:
        r = c.get("/reservationApi/v1/allMotels", params=params)
        r.raise_for_status()
        return r.json()

@retry_policy()
def _post_reservation(payload: Dict[str, Any]) -> Dict[str, Any]:
    with client() as c:
        r = c.post("/reservationApi/v1/reservation", json=payload)
        r.raise_for_status()
        try:
            return r.json()
        except Exception:
            return {"status_code": r.status_code}

# ---------- extraction ----------
def _extract_one_candidate(
    page_start: int,
    per_page: int,
    page_param: str,
    per_page_param: str,
    desired_room_type: Optional[str],
    desired_date: Optional[str],
) -> Optional[Dict[str, Any]]:
    page = page_start
    seen_pages = 0
    while True:
        body = _fetch_availability(page, per_page, page_param, per_page_param)
        items = _items(body)
        for it in items:
            status_ok = (it.get("status") or "").strip().lower() == "active"
            # available_room_number may be string -> cast to int safely
            try:
                avail = int(str(it.get("available_room_number", "0")))
            except Exception:
                avail = 0
            type_ok = True if not desired_room_type else (it.get("room_type") == desired_room_type)
            date_ok = True if not desired_date else (it.get("date") == desired_date)

            if status_ok and avail > 0 and type_ok and date_ok:
                return it

        seen_pages += 1
        pg = _pagination(body)
        if not pg:
            break
        current_page = int(pg.get("current_page", page))
        has_next = _bool(pg.get("has_next"))
        total_pages = pg.get("total_pages")

        if not has_next:
            break
        if total_pages is not None and current_page >= int(total_pages):
            break

        next_page = current_page + 1
        if next_page == page:
            break
        page = next_page

    log.warning(json.dumps({"event": "no_candidate_found", "pages_scanned": seen_pages}))
    return None

def _extract_created_fields(resp: Dict[str, Any]) -> Dict[str, Optional[str]]:
    """
    Response example:
    { "response": { "http_code": "201", "data": { "data": { ... } } } }
    """
    try:
        data = resp["response"]["data"]["data"]
        return {
            "motel_reservation_id": str(data.get("motel_reservation_id")),
            "created_at": str(data.get("created_at") or data.get("createdAt")),
            "updated_at": str(data.get("updated_at") or data.get("updatedAt")),
        }
    except Exception:
        # fallback for variant shapes
        flat = resp.get("response", {}).get("data") or resp
        return {
            "motel_reservation_id": str(flat.get("motel_reservation_id") or flat.get("id") or ""),
            "created_at": str(flat.get("created_at") or flat.get("createdAt") or ""),
            "updated_at": str(flat.get("updated_at") or flat.get("updatedAt") or ""),
        }

# ---------- main entry ----------
def run_once():
    # ENV knobs
    start_page = int(os.getenv("START_PAGE", "1"))                 # sample shows 1-based
    per_page = int(os.getenv("RESV_PER_PAGE", "50"))
    page_param = os.getenv("RESV_PAGE_PARAM", "page")              # if API expects 'page'/'current_page'
    per_page_param = os.getenv("RESV_PER_PAGE_PARAM", "per_page")
    # Optional filters
    desired_room_type = os.getenv("RESV_ROOM_TYPE")                # e.g., "Deluxe Suite"
    desired_date = os.getenv("RESV_DATE")                          # e.g., "2025-08-16"
    # Poster identity/status
    name = os.getenv("RESERVATION_NAME", "John Doe")
    email = os.getenv("RESERVATION_EMAIL", "john.doe@example.com")
    status = os.getenv("RESERVATION_STATUS", "Confirmed")

    cand = _extract_one_candidate(start_page, per_page, page_param, per_page_param, desired_room_type, desired_date)
    if not cand:
        log.error(json.dumps({"event": "reservation_candidate_none"}))
        return

    # Build one-night stay payload from availability item
    # 'date' is the check-in; check-out is +1 day
    check_in_date = cand.get("date")
    try:
        dt_in = datetime.fromisoformat(check_in_date)  # "YYYY-MM-DD"
    except Exception:
        # if not a clean date string, fall back to today
        dt_in = datetime.utcnow()
        check_in_date = dt_in.date().isoformat()
    check_out_date = (dt_in + timedelta(days=1)).date().isoformat()

    payload = {
        "motel_id": cand.get("motel_id"),
        "motel_chain_id": cand.get("motel_chain_id"),
        "motel_room_category_id": cand.get("motel_room_category_id"),
        "motel_room_category_name": cand.get("room_type") or "Standard",
        "price": str(cand.get("price")),
        "status": status,
        "name": name,
        "email": email,
        "check_in": check_in_date,
        "check_out": check_out_date,
    }

    # Single POST (exactly one)
    try:
        resp = _post_reservation(payload)
        created = _extract_created_fields(resp)
        log.info(json.dumps({
            "event": "reservation_created",
            "motel_reservation_id": created.get("motel_reservation_id"),
            "created_at": created.get("created_at"),
            "updated_at": created.get("updated_at"),
            # context
            "motel_id": payload["motel_id"],
            "motel_chain_id": payload["motel_chain_id"],
            "motel_room_category_id": payload["motel_room_category_id"],
            "motel_room_category_name": payload["motel_room_category_name"],
            "price": payload["price"],
            "check_in": payload["check_in"],
            "check_out": payload["check_out"],
        }))
    except Exception as e:
        log.error(json.dumps({
            "event": "reservation_create_failed",
            "error": str(e),
            "payload": payload
        }))
