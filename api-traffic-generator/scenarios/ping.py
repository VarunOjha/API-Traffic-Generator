import json, logging, time
from ..http_client import client, retry_policy
from ..config import get_settings

log = logging.getLogger("ping")
_settings = get_settings()

EXPECTED = {"response": {"http_code": "200", "data": "pong"}}

def _body_matches(body: dict) -> bool:
    try:
        resp = body["response"]
        # accept "200" or 200 for robustness
        code = str(resp.get("http_code"))
        return code == "200" and resp.get("data") == "pong"
    except Exception:
        return False

@retry_policy()
def run_once():
    with client() as c:
        r = c.get("/motelApi/v1/ping")
        r.raise_for_status()
        body = None
        ok = False
        try:
            body = r.json()
            ok = _body_matches(body)
        except Exception:
            ok = False

        if ok:
            log.info(json.dumps({
                "event": "ping_ok",
                "status_code": r.status_code,
            }))
        else:
            log.error(json.dumps({
                "event": "ping_unexpected_body",
                "status_code": r.status_code,
                "body": body,
            }))

def run_loop_every_second():
    """Run for DURATION_SECONDS (default 60), hitting ping once per second."""
    end = time.time() + _settings.duration_seconds
    while time.time() < end:
        try:
            run_once()
        except Exception as e:
            log.error(json.dumps({"event": "ping_error", "error": str(e)}))
        time.sleep(1)
