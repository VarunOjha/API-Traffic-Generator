import json, logging
from ..http_client import client, retry_policy

log = logging.getLogger("get_motels_count")

@retry_policy()
def run_once():
    with client() as c:
        url = "/motelApi/v1/allMotels/count"
        full_url = f"{c.base_url}{url}"
        log.info(json.dumps({"event":"get_motels_count_request","url":full_url,"method":"GET"}))
        
        try:
            r = c.get(url)
            r.raise_for_status()
            
            # Log response details
            log.info(json.dumps({
                "event": "get_motels_count_response",
                "url": full_url,
                "status_code": r.status_code,
                "response_headers": dict(r.headers),
                "response_size": len(r.content) if r.content else 0
            }))
            
            body = r.json()
            
            # Extract key metrics from response
            response_data = body.get("response", {}).get("data", {})
            postgresql_tables = response_data.get("postgresql_tables", {})
            total_records = response_data.get("total_postgresql_records", 0)
            
            log.info(json.dumps({
                "event": "get_motels_count_success",
                "status_code": r.status_code,
                "motel_chains": postgresql_tables.get("motel_chains", 0),
                "motels": postgresql_tables.get("motels", 0),
                "rooms": postgresql_tables.get("rooms", 0),
                "room_categories": postgresql_tables.get("room_categories", 0),
                "total_postgresql_records": total_records,
                "note": response_data.get("note", ""),
                "full_response": body
            }))
            
        except Exception as e:
            # Log detailed failure response
            error_data = {
                "event": "get_motels_count_failed",
                "url": full_url,
                "error": str(e),
                "error_type": type(e).__name__
            }
            
            # Add response details if available
            if hasattr(e, 'response') and e.response is not None:
                error_data.update({
                    "status_code": e.response.status_code,
                    "response_headers": dict(e.response.headers),
                })
                try:
                    error_data["response_body"] = e.response.json()
                except:
                    try:
                        error_data["response_text"] = e.response.text
                    except:
                        error_data["response_text"] = "Could not read response body"
            
            log.error(json.dumps(error_data))
            raise
