import os, sys, logging
from .logging import setup_logging
from .config import get_settings
from .scenarios.post_motel_chain import run_once as post_chain_once

from .scenarios.ping import run_once as ping_once


TASKS = {
    "post_motel_chain": post_chain_once,
    "ping_once": ping_once, 
}

def main():
    setup_logging(get_settings().log_level)
    task = os.environ.get("TASK")
    if task not in TASKS:
        print(f"Unknown or missing TASK. Valid: {list(TASKS)}", file=sys.stderr)
        sys.exit(2)
    TASKS[task]()

if __name__ == "__main__":
    main()
