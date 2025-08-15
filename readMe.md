# API Traffic Generator

Practice project where I (with help from **GPT-5**) built a small, reusable framework to:
- run **API E2E tests**,  
- **seed** realistic data, and  
- **emulate steady/periodic traffic** via **Kubernetes CronJobs**.  

It focuses on testing, metrics gathering, and learning how systems behave and scale under load.

## Context

- Why: Quickly spin up repeatable API calls (GET/POST) with realistic payloads, capture JSON logs, and schedule them in Kubernetes for continuous signal.
- What: A tiny Python framework (“scenarios”) + Docker image + K8s CronJobs. Add new flows by dropping a file in scenarios/ and wiring an env var.
- How: httpx with retries/timeouts, faker for realistic data, JSON logs for easy ingestion (ELK/CloudWatch/Grafana Loki).

---

## Project Structure

```
API-Traffic-Generator/
  README.md
  requirements.txt
  trafficgen/
    __init__.py
    config.py             # env-driven settings (BASE_URL, TASK, timeouts, etc.)
    http_client.py        # httpx client + retry policy
    logging.py            # JSON logging formatter
    run_task.py           # dispatch TASK -> scenario
    data_generators/
      __init__.py
      motel_chain.py      # realistic data for motel chain POST
      reservation.py      # derives reservation payload from price list
    scenarios/
      __init__.py
      ping.py             # GET /motelApi/v1/ping validator (example below)
      post_motel_chain.py # POST /motelApi/v1/motels/chains seeder
      get_all_motels.py   # GET /motelApi/v1/allmotels every second (loop)
      price_to_reservation.py # GET priceList -> POST reservation
  docker/
    Dockerfile
  k8s/
    namespace.yaml
    configmap.yaml
    secret-sample.yaml
    cronjob-ping.yaml
    cronjob-post-motel-chain.yaml
    cronjob-get-all-motels.yaml
    cronjob-reservation.yaml
```

### Key Ideas
- Scenario = one Python function you can run once or in a time-bounded loop.
- Generators create realistic payloads (names, addresses, dates).
- Env vars control everything: TASK, BASE_URL, DURATION_SECONDS, API_TOKEN, …
- JSON logs to stdout for metrics/troubleshooting.

