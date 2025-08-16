import os, json, logging
from typing import Any, Dict, List, Optional
from ..http_client import client, retry_policy

log = logging.getLogger("get_motel_rooms")

# ---------- helpers to read common shape ----------
def _content(body: Dict[str, Any]) -> List[Dict[str, Any]]:
    # Expected path: response -> data -> content (list)
    try:
        return body["response"]["data"]["content"] or []
    except Exception:
        return []

def _pagination(body: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    try:
        return body["response"]["data"]["pagination"] or None
    except Exception:
        return None

def _is_last(pg: Optional[Dict[str, Any]], current_page: int) -> bool:
    if not pg:
        return True
    if pg.get("last") or pg.get("is_last"):
        return True
    total_pages = pg.get("total_pages")
    if total_pages is not None and int(current_page) >= int(total_pages) - 1:
        return True
    return False

# ---------- API fetch ----------
@retry_policy()
def _fetch_rooms_page(page: int, size: int) -> Dict[str, Any]:
    with client() as c:
        r = c.get("/motelApi/v1/motelRooms", params={"page": page, "size": size})
        r.raise_for_status()
        return r.json()

# ---------- main entry ----------
def run_once():
    page = 0
    size = int(os.getenv("PAGE_SIZE", "50"))
    total_logged = 0
    last_page_seen = 0

    while True:
        body = _fetch_rooms_page(page, size)
        items = _content(body)

        for it in items:
            created = it.get("created_at") or it.get("createdAt")
            log.info(json.dumps({
                "event": "motel_room",
                "page": page,
                "roomId": it.get("roomId") or it.get("id"),
                "created_at": created,
                # optional context:
                "motelId": it.get("motelId"),
                "motelChainId": it.get("motelChainId"),
                "roomNumber": it.get("roomNumber"),
                "floor": it.get("floor"),
                "status": it.get("status"),
            }))
            total_logged += 1

        pg = _pagination(body)
        last_page_seen = page
        if _is_last(pg, page):
            break
        page = int(pg.get("page", page)) + 1

    log.info(json.dumps({
        "event": "motel_rooms_paging_done",
        "pages_traversed_up_to": last_page_seen,
        "total_records_logged": total_logged
    }))
