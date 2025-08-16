import os, json, logging
from uuid import uuid4
from typing import Any, Dict, List, Optional
from ..http_client import client, retry_policy

log = logging.getLogger("seed_room_categories")

# ---------- Defaults (can override via env) ----------
DEFAULT_CATEGORIES = [
    {
        "displayName": "Regular Room",
        "roomCategoryName": "Regular",
        "description": "Regular room 400 sqft",
    },
    {
        "displayName": "Deluxe Room",
        "roomCategoryName": "Deluxe",
        "description": "Spacious deluxe room with king bed, 550 sqft",
    },
    {
        "displayName": "Suite",
        "roomCategoryName": "Suite",
        "description": "Luxury suite with separate living area, 750 sqft",
    },
    {
        "displayName": "Economy Room",
        "roomCategoryName": "Economy",
        "description": "Compact and affordable room, 300 sqft",
    },
]

def _categories() -> List[Dict[str, str]]:
    """
    Optionally override categories via env var CATEGORIES_JSON (JSON array).
    If your JSON uses 'desicription' (typo), we normalize to 'description'.
    """
    raw = os.getenv("CATEGORIES_JSON")
    if not raw:
        return DEFAULT_CATEGORIES
    try:
        import json as _json
        arr = _json.loads(raw)
        norm = []
        for c in arr:
            d = dict(c)
            if "description" not in d and "desicription" in d:
                d["description"] = d.pop("desicription")
            norm.append(d)
        return norm
    except Exception:
        return DEFAULT_CATEGORIES

# ---------- helpers for common response shape ----------
def _content(body: Dict[str, Any]) -> List[Dict[str, Any]]:
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

# ---------- API calls ----------
@retry_policy()
def _fetch_motels_page(page: int, size: int) -> Dict[str, Any]:
    with client() as c:
        r = c.get("/motelApi/v1/motels", params={"page": page, "size": size})
        r.raise_for_status()
        return r.json()

@retry_policy()
def _post_room_category(path: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    with client() as c:
        r = c.post(path, json=payload)
        r.raise_for_status()
        try:
            return r.json()
        except Exception:
            return {"status_code": r.status_code}

# ---------- main entry ----------
def run_once():
    page = 0
    size = int(os.getenv("PAGE_SIZE", "50"))
    only_active = os.getenv("ONLY_ACTIVE", "true").lower() in ("1", "true", "yes")
    category_status = os.getenv("ROOM_CATEGORY_STATUS", "Active")
    # Default endpoint; override via ROOM_CATEGORY_PATH if your API differs
    path = os.getenv("ROOM_CATEGORY_PATH", "/motelApi/v1/motelRoomCategories")

    cats = _categories()
    total_posts = 0
    motels_seen = 0

    while True:
        body = _fetch_motels_page(page, size)
        items = _content(body)

        for m in items:
            motel_id = m.get("motelId")
            chain_id = m.get("motelChainId")
            status = (m.get("status") or "").strip()

            if not motel_id or not chain_id:
                log.error(json.dumps({
                    "event": "motels_missing_ids",
                    "page": page,
                    "record": m
                }))
                continue

            if only_active and status.lower() != "active":
                continue

            motels_seen += 1

            # Create each category for this motel
            for cdef in cats:
                payload = {
                    "motelRoomCategoryId": str(uuid4()),
                    "motelChainId": chain_id,
                    "motelId": motel_id,
                    "displayName": cdef.get("displayName"),
                    "roomCategoryName": cdef.get("roomCategoryName"),
                    "description": cdef.get("description") or cdef.get("desicription") or "",
                    "status": category_status,
                }

                try:
                    resp = _post_room_category(path, payload)
                    total_posts += 1
                    log.info(json.dumps({
                        "event": "room_category_created",
                        "motelId": motel_id,
                        "motelChainId": chain_id,
                        "roomCategoryName": payload["roomCategoryName"],
                        "motelRoomCategoryId": payload["motelRoomCategoryId"],
                        "api_path": path,
                        "resp": resp if isinstance(resp, dict) else None
                    }))
                except Exception as e:
                    log.error(json.dumps({
                        "event": "room_category_create_failed",
                        "motelId": motel_id,
                        "motelChainId": chain_id,
                        "roomCategoryName": payload["roomCategoryName"],
                        "error": str(e)
                    }))

        pg = _pagination(body)
        if _is_last(pg, page):
            break
        page = int(pg.get("page", page)) + 1

    log.info(json.dumps({
        "event": "seed_room_categories_done",
        "motels_processed": motels_seen,
        "total_categories_posted": total_posts,
        "pages_traversed_up_to": page
    }))
