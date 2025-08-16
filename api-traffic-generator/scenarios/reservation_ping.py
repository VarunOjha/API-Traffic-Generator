import json, logging, time
from ..http_client import client, retry_policy
from ..config import get_settings

log = logging.getLogger("reservation_ping")
_settings = get_settings()

EXPECTED_DB = "working fine"
EXPECTED_MSG = "pong"

def _body_matches(body: dict) -> bool:
    try:
        resp = body["response"]
        code = str(resp.get("http_code"))
        data = resp.get("data") or {}
        return (
            code == "200"
            and data.get("database") == EXPECTED_DB
            and data.get("message") == EXPECTED_MSG
        )
    except Exception:
        return False

@retry_policy()
def run_once():
    with client() as c:
        r = c.get("/reservationApi/v1/ping")
        r.raise_for_status()
        body = None
        ok = False
        try:
            body = r.json()
            ok = _body_matches(body)
        except Exception:
            ok = False

        if ok:
            # surface the values that matter
            data = body["response"]["data"]
            log.info(json.dumps({
                "event": "reservation_ping_ok",
                "status_code": r.status_code,
                "database": data.get("database"),
                "message": data.get("message"),
            }))
        else:
            log.error(json.dumps({
                "event": "reservation_ping_unexpected_body",
                "status_code": r.status_code,
                "body": body,
            }))

def run_loop_every_second():
    """Run for DURATION_SECONDS (default 60), hitting reservation ping once per second."""
    end = time.time() + _settings.duration_seconds
    while time.time() < end:
        try:
            run_once()
        except Exception as e:
            log.error(json.dumps({"event": "reservation_ping_error", "error": str(e)}))
        time.sleep(1)
