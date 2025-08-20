import os, json, logging
from typing import Any, Dict, List, Optional, Set
import httpx
from ..http_client import client, retry_policy

log = logging.getLogger("post_motel_from_chain_all")

# Maximum number of motels allowed
MAX_MOTEL = 50

@retry_policy()
def get_motels_count():
    """Fetch the current count of motels from the API"""
    with client() as c:
        url = "/motelApi/v1/allMotels/count"
        full_url = f"{c.base_url}{url}"
        log.info(json.dumps({"event":"get_motels_count_check","url":full_url,"method":"GET"}))
        
        try:
            r = c.get(url)
            r.raise_for_status()
            body = r.json()
            
            # Extract motels count
            response_data = body.get("response", {}).get("data", {})
            postgresql_tables = response_data.get("postgresql_tables", {})
            motels_count = postgresql_tables.get("motels", 0)
            
            log.info(json.dumps({
                "event": "get_motels_count_check_success",
                "motels_count": motels_count,
                "max_allowed": MAX_MOTEL
            }))
            
            return motels_count
            
        except Exception as e:
            log.error(json.dumps({
                "event": "get_motels_count_check_failed",
                "error": str(e),
                "error_type": type(e).__name__
            }))
            # If we can't get the count, allow the creation to proceed
            return 0

# ---------- helpers for chain list shape ----------
def _chains(body: Dict[str, Any]) -> List[Dict[str, Any]]:
    # Expect: { response: { data: { content: [ ... ] } } }
    try:
        data = body["response"]["data"]
        if isinstance(data, dict) and isinstance(data.get("content"), list):
            return data["content"]
        return []
    except Exception:
        return []

def _pagination(body: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    try:
        return body["response"]["data"]["pagination"]
    except Exception:
        return None

def _is_last(pg: Optional[Dict[str, Any]], page: int) -> bool:
    if not pg:
        return True
    if pg.get("last") or pg.get("is_last"):
        return True
    total_pages = pg.get("total_pages")
    if total_pages is not None and int(page) >= int(total_pages) - 1:
        return True
    return False

# ---------- API calls ----------
@retry_policy()
def _fetch_chains_page(page: int, size: int, path: str) -> Dict[str, Any]:
    with client() as c:
        r = c.get(path, params={"page": page, "size": size})
        r.raise_for_status()
        return r.json()

@retry_policy()
def _post_motel(payload: Dict[str, Any]) -> Dict[str, Any]:
    with client() as c:
        r = c.post("/motelApi/v1/motels", json=payload)
        r.raise_for_status()
        try:
            return r.json()
        except Exception:
            return {"status_code": r.status_code}

# ---------- filtering & payload ----------
def _parse_allowed_statuses() -> Set[str]:
    """
    CHAIN_ALLOWED_STATUS can be a comma-separated list (e.g., "Active,Inactive").
    If unset or empty -> include ALL statuses.
    """
    raw = os.getenv("CHAIN_ALLOWED_STATUS", "").strip()
    if not raw:
        return set()  # no filter
    return {s.strip().lower() for s in raw.split(",") if s.strip()}

def _include_chain(chain: Dict[str, Any], allowed: Set[str]) -> bool:
    if not allowed:
        return True
    st = (chain.get("status") or "").strip().lower()
    return st in allowed

def _compose_payload(chain: Dict[str, Any]) -> Dict[str, Any]:
    """
    Build the POST body from the chain.
    You can customize the name via MOTEL_NAME_SUFFIX or MOTEL_NAME_TEMPLATE.
    """
    chain_id = chain.get("motelChainId") or chain.get("id")
    chain_name = chain.get("motelChainName") or chain.get("displayName") or "Motel Chain"

    # Name controls (pick one approach)
    suffix = os.getenv("MOTEL_NAME_SUFFIX", "Motel1")
    template = os.getenv("MOTEL_NAME_TEMPLATE", "{chain} - " + suffix)
    motel_name = template.format(chain=chain_name)

    return {
        "motelChainId": chain_id,
        "motelName": motel_name,
        "status": os.getenv("MOTEL_STATUS", "Active"),
        "pincode": chain.get("pincode") or os.getenv("MOTEL_PINCODE", "00000"),
        "state": chain.get("state") or os.getenv("MOTEL_STATE", "TX"),
    }

def _extract_created_fields(resp: Dict[str, Any]) -> Dict[str, Optional[str]]:
    # Expect: {response:{http_code:"201", data:{motelId, createdAt, updatedAt, ...}}}
    try:
        data = resp["response"]["data"]
        return {
            "motelId": str(data.get("motelId")),
            "createdAt": str(data.get("createdAt") or data.get("created_at")),
            "updatedAt": str(data.get("updatedAt") or data.get("updated_at")),
        }
    except Exception:
        return {
            "motelId": str(resp.get("motelId") or resp.get("id") or ""),
            "createdAt": str(resp.get("createdAt") or resp.get("created_at") or ""),
            "updatedAt": str(resp.get("updatedAt") or resp.get("updated_at") or ""),
        }

# ---------- main entry ----------
def run_once():
    # First check current motels count
    current_count = get_motels_count()
    
    if current_count >= MAX_MOTEL:
        log.info(json.dumps({
            "event": "post_motel_from_chain_skipped",
            "reason": "maximum_motels_reached",
            "current_count": current_count,
            "max_allowed": MAX_MOTEL,
            "message": f"Cannot create new motels. Current count ({current_count}) has reached or exceeded maximum allowed ({MAX_MOTEL})"
        }))
        return
    
    # Proceed with creating new motels
    log.info(json.dumps({
        "event": "post_motel_from_chain_proceeding",
        "current_count": current_count,
        "max_allowed": MAX_MOTEL
    }))
    
    page = 0
    size = int(os.getenv("PAGE_SIZE", "50"))
    path = os.getenv("CHAIN_GET_PATH", "/motelApi/v1/motelChains")
    allowed_statuses = _parse_allowed_statuses()  # empty set == include all

    chains_seen = 0
    posted = 0
    failed = 0
    pages_traversed = 0

    while True:
        body = _fetch_chains_page(page, size, path)
        items = _chains(body)

        for ch in items:
            chains_seen += 1
            if not _include_chain(ch, allowed_statuses):
                continue

            payload = _compose_payload(ch)

            try:
                resp = _post_motel(payload)
                out = _extract_created_fields(resp)
                posted += 1
                log.info(json.dumps({
                    "event": "motel_created",
                    "motelChainId": payload["motelChainId"],
                    "motelName": payload["motelName"],
                    "state": payload["state"],
                    "pincode": payload["pincode"],
                    "motelId": out.get("motelId"),
                    "createdAt": out.get("createdAt"),
                    "updatedAt": out.get("updatedAt"),
                }))
            except httpx.HTTPStatusError as e:
                failed += 1
                code = e.response.status_code if e.response is not None else None
                log.error(json.dumps({
                    "event": "motel_create_failed",
                    "http_status": code,
                    "error": str(e),
                    "payload": payload
                }))
            except Exception as e:
                failed += 1
                log.error(json.dumps({
                    "event": "motel_create_failed",
                    "error": str(e),
                    "payload": payload
                }))

        pg = _pagination(body)
        pages_traversed = page
        if _is_last(pg, page):
            break
        page = int(pg.get("page", page)) + 1

    log.info(json.dumps({
        "event": "post_motel_from_chain_all_done",
        "pages_traversed_up_to": pages_traversed,
        "chains_seen": chains_seen,
        "motels_posted": posted,
        "motels_failed": failed,
        "status_filter": list(allowed_statuses) if allowed_statuses else "ALL"
    }))
