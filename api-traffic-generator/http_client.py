import httpx
from tenacity import retry, stop_after_attempt, wait_exponential, retry_if_exception_type
from .config import get_settings

_settings = get_settings()

def _headers():
    h = {"Content-Type": "application/json"}
    if _settings.api_token:
        h["Authorization"] = f"Bearer {_settings.api_token}"
    return h

def client():
    return httpx.Client(
        base_url=_settings.base_url.rstrip("/"),
        headers=_headers(),
        timeout=httpx.Timeout(_settings.read_timeout, connect=_settings.connect_timeout),
    )

# Decorator usable for both GET/POST helpers
def retry_policy():
    return retry(
        reraise=True,
        stop=stop_after_attempt(4),
        wait=wait_exponential(multiplier=0.25, max=4),
        retry=retry_if_exception_type((httpx.TimeoutException, httpx.TransportError)),
    )
