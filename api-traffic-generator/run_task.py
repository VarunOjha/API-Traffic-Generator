import os, sys, logging
from .logging import setup_logging
from .config import get_settings
from .scenarios.post_motel_chain import run_once as post_chain_once

from .scenarios.ping import run_once as ping_once
from .scenarios.get_motel_chains import run_once as get_motel_chains_once
from .scenarios.get_motels import run_once as get_motels_once
from .scenarios.seed_room_categories import run_once as seed_room_categories_once
from .scenarios.get_room_categories import run_once as get_room_categories_once
from .scenarios.seed_motel_rooms import run_once as seed_motel_rooms_once 
from .scenarios.get_motel_rooms import run_once as get_motel_rooms_once
from .scenarios.get_motels_count import run_once as get_motels_count_once
from .scenarios.reservation_ping import run_once as reservation_ping_once
from .scenarios.reservation_all_motels import run_once as reservation_all_motels_once
from .scenarios.reservation_from_availability import run_once as reservation_from_availability_once
from .scenarios.reservation_all_bookings import run_once as reservation_all_bookings_once
from .scenarios.reservation_by_ids import run_once as reservation_by_ids_once 
from .scenarios.post_motel_from_chain import run_once as post_motel_from_chain_once  # NEW





TASKS = {
    "post_motel_chain": post_chain_once,
    "ping_once": ping_once,
    "get_motel_chains": get_motel_chains_once,
    "get_motels": get_motels_once,
    "seed_room_categories": seed_room_categories_once,
    "seed_motel_rooms": seed_motel_rooms_once,
    "get_room_categories": get_room_categories_once,
    "get_motel_rooms": get_motel_rooms_once,
    "get_motels_count": get_motels_count_once,
    "reservation_ping_once": reservation_ping_once,
    "reservation_all_motels": reservation_all_motels_once,
    "reservation_from_availability": reservation_from_availability_once,
    "reservation_all_bookings": reservation_all_bookings_once,
    "reservation_by_ids": reservation_by_ids_once,
    "post_motel_from_chain": post_motel_from_chain_once,
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
