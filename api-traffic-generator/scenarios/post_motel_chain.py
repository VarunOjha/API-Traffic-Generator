import json, logging
import httpx
from ..http_client import client, retry_policy
from ..data_generators.motel_chain import motel_chain_payload

log = logging.getLogger("post_motel_chain")

# Maximum number of motel chains allowed
MAX_MOTEL_CHAINS = 10

@retry_policy()
def get_motels_count():
    """Fetch the current count of motel chains from the API"""
    with client() as c:
        url = "/motelApi/v1/allMotels/count"
        full_url = f"{c.base_url}{url}"
        log.info(json.dumps({"event":"get_motels_count_check","url":full_url,"method":"GET"}))
        
        try:
            r = c.get(url)
            r.raise_for_status()
            body = r.json()
            
            # Extract motel chains count
            response_data = body.get("response", {}).get("data", {})
            postgresql_tables = response_data.get("postgresql_tables", {})
            motel_chains_count = postgresql_tables.get("motel_chains", 0)
            
            log.info(json.dumps({
                "event": "get_motels_count_check_success",
                "motel_chains_count": motel_chains_count,
                "max_allowed": MAX_MOTEL_CHAINS
            }))
            
            return motel_chains_count
            
        except Exception as e:
            log.error(json.dumps({
                "event": "get_motels_count_check_failed",
                "error": str(e),
                "error_type": type(e).__name__
            }))
            # If we can't get the count, allow the creation to proceed
            return 0

@retry_policy()
def run_once():
    # First check current motel chains count
    current_count = get_motels_count()
    
    if current_count >= MAX_MOTEL_CHAINS:
        log.info(json.dumps({
            "event": "post_motel_chain_skipped",
            "reason": "maximum_motel_chains_reached",
            "current_count": current_count,
            "max_allowed": MAX_MOTEL_CHAINS,
            "message": f"Cannot create new motel chain. Current count ({current_count}) has reached or exceeded maximum allowed ({MAX_MOTEL_CHAINS})"
        }))
        return
    
    # Proceed with creating new motel chain
    log.info(json.dumps({
        "event": "post_motel_chain_proceeding",
        "current_count": current_count,
        "max_allowed": MAX_MOTEL_CHAINS
    }))
    
    payload = motel_chain_payload()
    log.info(json.dumps({"event":"post_motel_chain_payload","payload":payload}))
    
    try:
        with client() as c:
            url = "/motelApi/v1/motelChains"
            full_url = f"{c.base_url}{url}"
            log.info(json.dumps({"event":"post_motel_chain_request","url":full_url,"method":"POST"}))
            
            r = c.post(url, json=payload)
            r.raise_for_status()
            log.info(json.dumps({"event":"post_motel_chain_success","status_code":r.status_code,"id":r.json().get("id") if r.headers.get("content-type","").startswith("application/json") else None}))
            
    except httpx.ConnectError as e:
        log.error(json.dumps({"event":"post_motel_chain_connect_error","error":str(e),"url":full_url}))
        raise
    except httpx.TimeoutException as e:
        log.error(json.dumps({"event":"post_motel_chain_timeout","error":str(e),"url":full_url}))
        raise
    except httpx.TransportError as e:
        log.error(json.dumps({"event":"post_motel_chain_transport_error","error":str(e),"url":full_url}))
        raise
    except httpx.HTTPStatusError as e:
        log.error(json.dumps({"event":"post_motel_chain_http_error","status_code":e.response.status_code,"error":str(e),"url":full_url}))
        raise
    except Exception as e:
        log.error(json.dumps({"event":"post_motel_chain_unknown_error","error":str(e),"error_type":type(e).__name__}))
        raise
