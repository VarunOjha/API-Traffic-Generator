import os, json, logging
from typing import Any, Dict, List, Optional
from ..http_client import client, retry_policy

log = logging.getLogger("get_motels")

# ---------- helpers to read common shape ----------
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

# ---------- paged fetchers ----------
@retry_policy()
def _fetch_motels_page(page: int, size: int) -> Dict[str, Any]:
    with client() as c:
        r = c.get("/motelApi/v1/motels", params={"page": page, "size": size})
        r.raise_for_status()
        return r.json()

@retry_policy()
def _fetch_chains_page(page: int, size: int) -> Dict[str, Any]:
    with client() as c:
        r = c.get("/motelApi/v1/motelChains", params={"page": page, "size": size})
        r.raise_for_status()
        return r.json()

def _is_last(pg: Optional[Dict[str, Any]], current_page: int) -> bool:
    if not pg:
        return True
    if pg.get("last") or pg.get("is_last"):
        return True
    total_pages = pg.get("total_pages")
    if total_pages is not None and int(current_page) >= int(total_pages) - 1:
        return True
    return False

# ---------- optional enrichment: chainId -> chainName ----------
def _build_chain_lookup(size: int) -> Dict[str, str]:
    page = 0
    lookup: Dict[str, str] = {}
    while True:
        body = _fetch_chains_page(page, size)
        for item in _content(body):
            cid = item.get("motelChainId") or item.get("id")
            name = item.get("motelChainName") or item.get("displayName")
            if cid and name:
                lookup[cid] = name
        pg = _pagination(body)
        if _is_last(pg, page):
            break
        page = int(pg.get("page", page)) + 1
    log.info(json.dumps({"event": "chain_lookup_ready", "size": len(lookup)}))
    return lookup

# ---------- main entry ----------
def run_once():
    page = 0
    size = int(os.getenv("PAGE_SIZE", "50"))
    enrich = os.getenv("CHAIN_LOOKUP", "true").lower() in ("1", "true", "yes")
    chain_name_by_id: Dict[str, str] = {}

    if enrich:
        try:
            chain_name_by_id = _build_chain_lookup(size=size)
        except Exception as e:
            log.error(json.dumps({"event": "chain_lookup_failed", "error": str(e)}))

    total = 0
    while True:
        body = _fetch_motels_page(page, size)
        items = _content(body)

        for m in items:
            cid = m.get("motelChainId")
            chain_name = m.get("motelChainName") or chain_name_by_id.get(cid)
            log.info(json.dumps({
                "event": "motel_record",
                "page": page,
                "motelId": m.get("motelId"),
                "motelChainId": cid,
                "motelChainName": chain_name,  # may be None if not available
                "state": m.get("state"),
                "pincode": m.get("pincode"),
                "status": m.get("status"),
            }))
            total += 1

        pg = _pagination(body)
        if _is_last(pg, page):
            break
        page = int(pg.get("page", page)) + 1

    log.info(json.dumps({
        "event": "motels_paging_done",
        "pages_traversed_up_to": page,
        "total_records_logged": total
    }))
