# API Traffic Generator

Practice project where I (with help from GPT-5) built a smEnsure your API is reachable. If it runs These manifests assume you already have a K```bash
# Update the image reference insid1. Create `trafficgen/scenarios/<your_flow>.py` with a `run_once()` (and optionally a loop).
2. If you need synthetic data, add a generator in `trafficgen/data_generators/`.
3. Register it in `trafficgen/run_task.py`'s TASKS dict.
4. Run locally by setting `TASK=<your_task>` and `BASE_URL=....`
5. Copy an existing CronJob YAML, swap TASK, and apply.

**Common env vars:**
- `TASK` – which scenario to run (e.g., `ping_loop`)
- `BASE_URL` – API root (no trailing slash)
- `DURATION_SECONDS` – how long loop scenarios run
- `API_TOKEN` – optional bearer token added as `Authorization: Bearer ...`
- `LOG_LEVEL` – INFO or DEBUG
- `CONNECT_TIMEOUT` / `READ_TIMEOUT` – seconds

---

## Futureyou pushed to a registry
kubectl -n motel-traffic apply -f k8s/cronjob-ping.yaml
kubectl -n motel-traffic get cronjobs
```

**3) Watch Jobs/Pods and logs**

```bash
# See Jobs created by the CronJob
kubectl -n motel-traffic get jobs --watch

# Get pods for latest job
kubectl -n motel-traffic get pods -l job-name=$(kubectl -n motel-traffic get jobs 
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')

# Tail logs from the latest pod (JSON lines)
LATEST_POD=$(kubectl -n motel-traffic get pods -o jsonpath='{.items[-1:].metadata.name}')
kubectl -n motel-traffic logs -f "$LATEST_POD"
```

---

## Extending (add your own scenario)and permissions to deploy.
If your cluster can't pull local images, push the image to a registry first (ECR/GHCR/Docker Hub) and update the `image:` fields.

**0) Build & (optionally) push**

```bash
docker buildx build --platform linux/amd64 -t <registry>/api-traffic-generator:latest -f docker/Dockerfile .
docker push <registry>/api-traffic-generator:latest
```

**1) Create namespace, config, and secret**

Edit `k8s/configmap.yaml` and set BASE_URL to your in-cluster service, e.g.:
`http://motel-api.default.svc.cluster.local:8085`

```bash
kubectl apply -f k8s/namespace.yaml
kubectl -n motel-traffic apply -f k8s/configmap.yaml
kubectl -n motel-traffic apply -f k8s/secret-sample.yaml   # put token if you need auth
```

**2) Deploy the ping CronJob**

`k8s/cronjob-ping.yaml` runs once per minute, and the container performs one request/second for 60 seconds.

```bashou're using Docker Desktop, use `host.docker.internal` rather than localhost from inside the container.

**1) Build the image**

```bash
docker build -t api-traffic-generator:latest -f docker/Dockerfile .
# On Apple Silicon building for amd64 Kubernetes nodes
docker buildx build --platform linux/amd64 -t api-traffic-generator:latest -f docker/Dockerfile .
```

**2) Smoke test: run the ping scenario**

```bashsable framework to:
- run API E2E tests,
- seed realistic data, and
- emulate steady/periodic traffic via Kubernetes CronJobs.

It focuses on testing, metrics gathering, and learning how systems behave and scale under load.

---

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

---

## One Scenario (Example): ping

**Goal:** call GET `/motelApi/v1/ping` and validate response equals

```json
{
  "response": { "http_code": "200", "data": "pong" }
}
```

**Files:**
- `trafficgen/scenarios/ping.py` – implements `run_once()` and `run_loop_every_second()`
- `k8s/cronjob-ping.yaml` – schedules ping_loop once per minute; the container loops every second for 60s

**TASK values:**
- `ping_once` — single request
- `ping_loop` — 1 request/sec for DURATION_SECONDS (default 60)

---

## Local (build & run)

Ensure your API is reachable. If it runs on your Mac and you’re using Docker Desktop, use host.docker.internal rather than localhost from inside the container.

1) Build the image
docker build -t api-traffic-generator:latest -f docker/Dockerfile .
# On Apple Silicon building for amd64 Kubernetes nodes
docker buildx build --platform linux/amd64 -t api-traffic-generator:latest -f docker/Dockerfile .

2) Smoke test: run the ping scenario
```bash
# Single request
docker run --rm 
  -e TASK=ping_once 
  -e BASE_URL=http://host.docker.internal:8085 
  api-traffic-generator:latest

# Per-second loop for a minute (logs in JSON)
docker run --rm 
  -e TASK=ping_loop 
  -e BASE_URL=http://host.docker.internal:8085 
  -e DURATION_SECONDS=60 
  api-traffic-generator:latest
```

Linux hosts: add `--add-host=host.docker.internal:host-gateway` and use `http://host.docker.internal:PORT`.

---

## Kubernetes (schedule with CronJobs)

These manifests assume you already have a Kubernetes cluster and permissions to deploy.
If your cluster can’t pull local images, push the image to a registry first (ECR/GHCR/Docker Hub) and update the image: fields.

0) Build & (optionally) push
docker buildx build --platform linux/amd64 -t <registry>/api-traffic-generator:latest -f docker/Dockerfile .
docker push <registry>/api-traffic-generator:latest

1) Create namespace, config, and secret
Edit k8s/configmap.yaml and set BASE_URL to your in-cluster service, e.g.:
http://motel-api.default.svc.cluster.local:8085

kubectl apply -f k8s/namespace.yaml
kubectl -n motel-traffic apply -f k8s/configmap.yaml
kubectl -n motel-traffic apply -f k8s/secret-sample.yaml   # put token if you need auth

2) Deploy the ping CronJob
k8s/cronjob-ping.yaml runs once per minute, and the container performs one request/second for 60 seconds.

# Update the image reference inside the CronJob if you pushed to a registry
kubectl -n motel-traffic apply -f k8s/cronjob-ping.yaml
kubectl -n motel-traffic get cronjobs

3) Watch Jobs/Pods and logs
# See Jobs created by the CronJob
kubectl -n motel-traffic get jobs --watch

# Get pods for latest job
kubectl -n motel-traffic get pods -l job-name=$(kubectl -n motel-traffic get jobs   --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')

# Tail logs from the latest pod (JSON lines)
LATEST_POD=$(kubectl -n motel-traffic get pods -o jsonpath='{.items[-1:].metadata.name}')
kubectl -n motel-traffic logs -f "$LATEST_POD"

---

Extending (add your own scenario)

1. Create trafficgen/scenarios/<your_flow>.py with a run_once() (and optionally a loop).
2. If you need synthetic data, add a generator in trafficgen/data_generators/.
3. Register it in trafficgen/run_task.py’s TASKS dict.
4. Run locally by setting TASK=<your_task> and BASE_URL=....
5. Copy an existing CronJob YAML, swap TASK, and apply.

Common env vars:
- TASK – which scenario to run (e.g., ping_loop)
- BASE_URL – API root (no trailing slash)
- DURATION_SECONDS – how long loop scenarios run
- API_TOKEN – optional bearer token added as Authorization: Bearer ...
- LOG_LEVEL – INFO or DEBUG
- CONNECT_TIMEOUT / READ_TIMEOUT – seconds

---

Future

- Traffic shapes: RPS caps, open/closed-loop, jittered schedules, weighted mixes of scenarios.
- Declarative profiles: YAML describing endpoints, weights, payload generators.
- Metrics: Export Prometheus metrics alongside JSON logs (latency histograms, error rates).
- Distributed runs: Parallel Jobs with shard-aware payload generators.
- CI hooks: Run smoke/E2E scenarios on every deploy.

---

## Notes

- JSON logs are emitted to stdout (great for ELK/Loki/CloudWatch).
- Retries use exponential backoff for transient failures.
- Remember: `localhost` inside a container ≠ your machine. Use `host.docker.internal` (or a Kubernetes Service DNS name in-cluster).

---

## License

MIT (or your choice). This is a practice project where I use GPT-5 to create the application. The purpose is to do testing, metrics gathering, and enable learning for scaling scenarios.
