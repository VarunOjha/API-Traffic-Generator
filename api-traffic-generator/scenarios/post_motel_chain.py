import json, logging
from ..http_client import client, retry_policy
from ..data_generators.motel_chain import motel_chain_payload

log = logging.getLogger("post_motel_chain")

@retry_policy()
def run_once():
    payload = motel_chain_payload()
    log.info(json.dumps({"event":"post_motel_chain_payload","payload":payload}))
    with client() as c:
        r = c.post("/motelApi/v1/motels/chains", json=payload)
        r.raise_for_status()
        log.info(json.dumps({"event":"post_motel_chain_success","status_code":r.status_code,"id":r.json().get("id") if r.headers.get("content-type","").startswith("application/json") else None}))
