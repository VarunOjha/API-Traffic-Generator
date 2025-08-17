import json, logging
import httpx
from ..http_client import client, retry_policy
from ..data_generators.motel_chain import motel_chain_payload

log = logging.getLogger("post_motel_chain")

@retry_policy()
def run_once():
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
