import os, json, logging
from typing import Any, Dict, List, Optional
from ..http_client import client, retry_policy

log = logging.getLogger("get_motel_chains")

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

@retry_policy()
def _fetch_page(page: int, size: int) -> Dict[str, Any]:
    with client() as c:
        r = c.get("/motelApi/v1/motelChains", params={"page": page, "size": size})
        r.raise_for_status()
        return r.json()

def run_once():
    page = 0
    size = int(os.getenv("PAGE_SIZE", "50"))
    total_logged = 0

    while True:
        body = _fetch_page(page, size)

        items = _content(body)
        for item in items:
            name = item.get("motelChainName") or item.get("displayName")
            log.info(json.dumps({
                "event": "motel_chain_name",
                "page": page,
                "motelChainId": item.get("motelChainId"),
                "motelChainName": name
            }))
            total_logged += 1

        pg = _pagination(body)
        # Fall back to total_pages if 'last' not available
        if pg:
            is_last = bool(pg.get("last") or pg.get("is_last"))
            current = int(pg.get("page", page))
            total_pages = pg.get("total_pages")
            if is_last or (total_pages is not None and current >= int(total_pages) - 1):
                break
            page = current + 1
        else:
            # No pagination section => single page
            break

    log.info(json.dumps({
        "event": "motel_chain_paging_done",
        "pages_traversed_up_to": page,
        "total_names_logged": total_logged
    }))
