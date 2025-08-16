import os, json, logging
from typing import Any, Dict, List, Optional
import httpx
from ..http_client import client, retry_policy

log = logging.getLogger("seed_motel_rooms")

# ---------- helpers for GET /motelApi/v1/motelRoomCategories ----------
def _items(body: Dict[str, Any]) -> List[Dict[str, Any]]:
    try:
        data = body["response"]["data"]
        return data if isinstance(data, list) else []
    except Exception:
        return []

@retry_policy()
def _fetch_room_categories() -> List[Dict[str, Any]]:
    with client() as c:
        r = c.get("/motelApi/v1/motelRoomCategories")
        r.raise_for_status()
        return _items(r.json())

# ---------- POST /motelApi/v1/motelRooms ----------
def _extract_room_id_and_updated_at(resp_body: Any) -> Dict[str, Optional[str]]:
    """
    Response might be either the created object or wrapped in {response:{data:{...}}}.
    Try to find keys case-insensitively: roomId/motelRoomId/id, updatedAt/updated_at.
    """
    def _flatten(x):
        if isinstance(x, dict) and "response" in x and isinstance(x["response"], dict):
            data = x["response"].get("data")
            return data if isinstance(data, dict) else x["response"]
        return x

    data = _flatten(resp_body) if isinstance(resp_body, dict) else {}
    # Search shallow keys
    room_id = None
    updated_at = None
    for k, v in data.items():
        lk = k.lower()
        if lk in ("roomid", "motelroomid", "motel_room_id", "id"):
            room_id = str(v)
        if lk in ("updatedat", "updated_at"):
            updated_at = str(v)
    # Fallback: sometimes nested again
    if room_id is None:
        for k, v in data.items():
            if isinstance(v, dict):
                for kk, vv in v.items():
                    lk = kk.lower()
                    if lk in ("roomid", "motelroomid", "motel_room_id", "id"):
                        room_id = str(vv)
                    if lk in ("updatedat", "updated_at"):
                        updated_at = str(vv)
    return {"roomId": room_id, "updated_at": updated_at}

@retry_policy()
def _post_room(payload: Dict[str, Any]) -> Dict[str, Any]:
    path = os.getenv("ROOM_POST_PATH", "/motelApi/v1/motelRooms")
    with client() as c:
        r = c.post(path, json=payload)
        r.raise_for_status()
        try:
            return r.json()
        except Exception:
            return {"status_code": r.status_code}

# ---------- room number generator ----------
def _make_room_number(floor: int, index_on_floor: int) -> str:
    """
    Default pattern: floor + 2-digit index (01..05).
    Examples: floor 0 -> 001..005; floor 3 -> 301..305
    """
    return f"{floor}{index_on_floor:02d}"

# ---------- main entry ----------
def run_once():
    # Configurable knobs
    floor_start = int(os.getenv("FLOOR_START", "0"))
    floor_end   = int(os.getenv("FLOOR_END", "3"))
    rooms_per_floor = int(os.getenv("ROOMS_PER_FLOOR", "5"))
    room_status = os.getenv("ROOM_STATUS", "Active")
    only_active_cats = os.getenv("ONLY_ACTIVE_CATEGORIES", "true").lower() in ("1", "true", "yes")

    categories = _fetch_room_categories()
    total_posts = 0
    categories_seen = 0

    for cat in categories:
        # Filter categories by status if requested
        cat_status = (cat.get("status") or "").strip()
        if only_active_cats and cat_status.lower() != "active":
            continue

        motel_chain_id = cat.get("motelChainId")
        motel_id = cat.get("motelId")
        category_id = cat.get("motelRoomCategoryId")
        display_name = cat.get("displayName") or cat.get("displyaName")

        if not (motel_chain_id and motel_id and category_id):
            log.error(json.dumps({
                "event": "room_category_missing_ids",
                "category": cat
            }))
            continue

        categories_seen += 1

        for floor in range(floor_start, floor_end + 1):
            for i in range(1, rooms_per_floor + 1):
                payload = {
                    "motelChainId": motel_chain_id,
                    "motelId": motel_id,
                    "motelRoomCategoryId": category_id,
                    "roomNumber": _make_room_number(floor, i),
                    "floor": str(floor),
                    "status": room_status,
                }

                try:
                    resp = _post_room(payload)
                    parsed = _extract_room_id_and_updated_at(resp)
                    total_posts += 1
                    log.info(json.dumps({
                        "event": "motel_room_created",
                        "motelChainId": motel_chain_id,
                        "motelId": motel_id,
                        "motelRoomCategoryId": category_id,
                        "categoryDisplayName": display_name,
                        "roomNumber": payload["roomNumber"],
                        "floor": payload["floor"],
                        "roomId": parsed.get("roomId"),
                        "updated_at": parsed.get("updated_at"),
                    }))
                except httpx.HTTPStatusError as e:
                    code = e.response.status_code if e.response is not None else None
                    log.error(json.dumps({
                        "event": "motel_room_create_failed",
                        "http_status": code,
                        "error": str(e),
                        "payload": payload
                    }))
                except Exception as e:
                    log.error(json.dumps({
                        "event": "motel_room_create_failed",
                        "error": str(e),
                        "payload": payload
                    }))

    log.info(json.dumps({
        "event": "seed_motel_rooms_done",
        "categories_processed": categories_seen,
        "total_rooms_posted": total_posts,
        "floors": f"{floor_start}-{floor_end}",
        "rooms_per_floor": rooms_per_floor
    }))
