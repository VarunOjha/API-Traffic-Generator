import os, json, logging
from typing import Any, Dict, List, Optional, Tuple
from ..http_client import client, retry_policy

log = logging.getLogger("reservation_by_ids")

# ---------- helpers for allbookings shape ----------
def _bookings_items(body: Dict[str, Any]) -> List[Dict[str, Any]]:
    try:
        data = body["response"]["data"]
        if isinstance(data, dict):
            inner = data.get("data")
            if isinstance(inner, list):
                return inner
        return data if isinstance(data, list) else []
    except Exception:
        return []

def _bookings_pagination(body: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    try:
        data = body["response"]["data"]
        return data.get("pagination") if isinstance(data, dict) else None
    except Exception:
        return None

def _truthy(x) -> bool:
    if isinstance(x, bool): return x
    if isinstance(x, str): return x.lower() in ("1","true","yes")
    return bool(x)

@retry_policy()
def _fetch_bookings_page(page: int, per_page: int, page_param: str, per_page_param: str) -> Dict[str, Any]:
    params = {page_param: page, per_page_param: per_page}
    with client() as c:
        r = c.get("/reservationApi/v1/allbookings", params=params)
        r.raise_for_status()
        return r.json()

def _pick_one_motel_ids(
    start_page: int,
    per_page: int,
    page_param: str,
    per_page_param: str,
) -> Optional[Tuple[str, str]]:
    page = start_page
    while True:
        body = _fetch_bookings_page(page, per_page, page_param, per_page_param)
        for it in _bookings_items(body):
            motel_id = it.get("motel_id")
            chain_id = it.get("motel_chain_id")
            if motel_id and chain_id:
                return motel_id, chain_id

        pg = _bookings_pagination(body)
        if not pg:
            break
        current_page = int(pg.get("current_page", page))
        has_next = _truthy(pg.get("has_next"))
        total_pages = pg.get("total_pages")

        if not has_next: break
        if total_pages is not None and current_page >= int(total_pages): break

        next_page = current_page + 1
        if next_page == page: break
        page = next_page
    return None

# ---------- reservation by ids ----------
def _reservations_items(body: Dict[str, Any]) -> List[Dict[str, Any]]:
    # Expected: { "response": { "http_code":"200", "data": [ ... ] } }
    try:
        data = body["response"]["data"]
        return data if isinstance(data, list) else []
    except Exception:
        return []

@retry_policy()
def _fetch_reservations_by_ids(motel_id: str, motel_chain_id: str) -> Dict[str, Any]:
    with client() as c:
        r = c.get("/reservationApi/v1/reservation", params={
            "motel_id": motel_id,
            "motel_chain_id": motel_chain_id
        })
        r.raise_for_status()
        return r.json()

# ---------- main entry ----------
def run_once():
    # allbookings paging knobs (1-based in your sample)
    start_page = int(os.getenv("START_PAGE", "1"))
    per_page = int(os.getenv("BOOKINGS_PER_PAGE", "50"))
    page_param = os.getenv("BOOKINGS_PAGE_PARAM", "page")
    per_page_param = os.getenv("BOOKINGS_PER_PAGE_PARAM", "per_page")

    # 1) find one (motel_id, motel_chain_id)
    ids = _pick_one_motel_ids(start_page, per_page, page_param, per_page_param)
    if not ids:
        log.error(json.dumps({"event": "reservation_ids_not_found"}))
        return
    motel_id, motel_chain_id = ids
    log.info(json.dumps({
        "event": "reservation_ids_selected",
        "motel_id": motel_id, "motel_chain_id": motel_chain_id
    }))

    # 2) GET /reservation with those IDs
    body = _fetch_reservations_by_ids(motel_id, motel_chain_id)
    items = _reservations_items(body)

    total = 0
    for it in items:
        log.info(json.dumps({
            "event": "reservation_by_ids",
            "motel_reservation_id": it.get("motel_reservation_id"),
            "motel_id": it.get("motel_id"),
            "motel_chain_id": it.get("motel_chain_id"),
            "motel_room_category_id": it.get("motel_room_category_id"),
            "motel_room_category_name": it.get("motel_room_category_name"),
            "price": it.get("price"),
            "status": it.get("status"),
            "name": it.get("name"),
            "email": it.get("email"),
            "check_in": it.get("check_in"),
            "check_out": it.get("check_out"),
            "created_at": it.get("created_at") or it.get("createdAt"),
            "updated_at": it.get("updated_at") or it.get("updatedAt"),
        }))
        total += 1

    log.info(json.dumps({
        "event": "reservation_by_ids_done",
        "total_records_logged": total
    }))
