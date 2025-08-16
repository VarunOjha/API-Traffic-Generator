import json, logging
from typing import Any, Dict, List
from ..http_client import client, retry_policy

log = logging.getLogger("get_room_categories")

def _items(body: Dict[str, Any]) -> List[Dict[str, Any]]:
    # Expected: { "response": { "http_code": "200", "data": [ ... ] } }
    try:
        data = body["response"]["data"]
        return data if isinstance(data, list) else []
    except Exception:
        return []

@retry_policy()
def run_once():
    with client() as c:
        r = c.get("/motelApi/v1/motelRoomCategories")
        r.raise_for_status()
        body = r.json()

    items = _items(body)
    total = 0

    for it in items:
        motel_id = it.get("motelId")
        chain_id = it.get("motelChainId")
        # be tolerant of a potential key typo: "displyaName"
        display = it.get("displayName") or it.get("displyaName")
        log.info(json.dumps({
            "event": "room_category",
            "motelId": motel_id,
            "motelChainId": chain_id,
            "displayName": display,
            "roomCategoryName": it.get("roomCategoryName"),
            "motelRoomCategoryId": it.get("motelRoomCategoryId"),
            "status": it.get("status"),
        }))
        total += 1

    log.info(json.dumps({
        "event": "room_categories_done",
        "total_logged": total,
        "http_status": 200
    }))
