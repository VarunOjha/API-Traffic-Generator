import os, json, logging
from typing import Any, Dict, List, Optional
from ..http_client import client, retry_policy

log = logging.getLogger("reservation_all_bookings")

# ----- helpers for the given shape -----
def _items(body: Dict[str, Any]) -> List[Dict[str, Any]]:
    # Expected:
    # { "response": { "http_code":"200", "data": { "data": [ ... ], "pagination": {...} } } }
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

# ----- API call -----
@retry_policy()
def _fetch(page: int, per_page: int, page_param: str, per_page_param: str) -> Dict[str, Any]:
    params = {page_param: page, per_page_param: per_page}
    with client() as c:
        r = c.get("/reservationApi/v1/allbookings", params=params)
        r.raise_for_status()
        return r.json()

# ----- main entry -----
def run_once():
    start_page = int(os.getenv("START_PAGE", "1"))          # sample shows 1-based pages
    per_page = int(os.getenv("BOOKINGS_PER_PAGE", "50"))
    page_param = os.getenv("BOOKINGS_PAGE_PARAM", "page")   # customize if API expects "current_page"
    per_page_param = os.getenv("BOOKINGS_PER_PAGE_PARAM", "per_page")

    page = start_page
    total_logged = 0
    pages_visited = 0

    while True:
        body = _fetch(page, per_page, page_param, per_page_param)
        items = _items(body)

        for it in items:
            log.info(json.dumps({
                "event": "reservation_booking",
                "motel_room_category_name": it.get("motel_room_category_name"),
                "motel_reservation_id": it.get("motel_reservation_id"),
                # optional context
                "status": it.get("status"),
                "price": it.get("price"),
                "check_in": it.get("check_in"),
                "check_out": it.get("check_out"),
            }))
            total_logged += 1

        pages_visited += 1
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
        if next_page == page:   # safety
            break
        page = next_page

    log.info(json.dumps({
        "event": "reservation_all_bookings_done",
        "pages_visited": pages_visited,
        "total_records_logged": total_logged
    }))
