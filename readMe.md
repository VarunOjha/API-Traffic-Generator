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
  infrastructre/
```

### Key Ideas

* **Scenario:** A single Python function that can be run once or in a time-bounded loop to generate traffic.
* **Generators:** Custom functions that create realistic payloads like names, addresses, and dates.
* **Environment Variables:** Control everything from the target API (`BASE_URL`) to the specific scenario (`TASK`) and its duration (`DURATION_SECONDS`).
* **JSON Logs:** All logs are structured in JSON and sent to `stdout`, making them easy to collect and analyze.

---

## Example Scenario: `ping`

The `ping` scenario is a simple example of how the framework works. Its goal is to call `GET /motelApi/v1/ping` and validate that the response matches the expected JSON.

* **Files:**
    * `trafficgen/scenarios/ping.py`: Contains the `run_once()` and `run_loop_every_second()` functions.
    * `k8s/cronjob-ping.yaml`: Schedules the `ping_loop` scenario to run once every minute.
* **Tasks:**
    * `ping_once`: Runs a single request.
    * `ping_loop`: Runs one request per second for the duration specified by `DURATION_SECONDS` (defaults to 60).

---

## Local Usage (Build & Run)

Make sure your target API is accessible from your local machine. If your API is running on a Mac and you're using Docker Desktop, use `host.docker.internal` instead of `localhost` inside the container.

1.  **Build the Docker image:**
    ```bash
    docker build -t api-traffic-generator:latest -f docker/Dockerfile .
    ```
    If you're on Apple Silicon and building for `amd64` Kubernetes nodes:
    ```bash
    docker buildx build --platform linux/amd64 -t api-traffic-generator:latest -f docker/Dockerfile .
    ```

2.  **Run a smoke test:**
    * **Single request:**
        ```bash
        docker run --rm \
          -e TASK=ping_once \
          -e BASE_URL=[http://host.docker.internal:8085](http://host.docker.internal:8085) \
          api-traffic-generator:latest
        ```
    * **Per-second loop:**
        ```bash
        docker run --rm \
          -e TASK=ping_loop \
          -e BASE_URL=[http://host.docker.internal:8085](http://host.docker.internal:8085) \
          -e DURATION_SECONDS=60 \
          api-traffic-generator:latest
        ```
    * ***Note for Linux hosts:*** Add `--add-host=host.docker.internal:host-gateway` to the `docker run` command.

---

## Kubernetes Usage (Schedule with CronJobs)

These instructions assume you have a Kubernetes cluster and the necessary permissions to deploy resources. If your cluster can't pull local images, you'll need to push the image to a registry first.

1.  **Build and push the image (optional):**
    ```bash
    docker buildx build --platform linux/amd64 -t <registry>/api-traffic-generator:latest -f docker/Dockerfile .
    docker push <registry>/api-traffic-generator:latest
    ```

2.  **Create resources:**
    * Edit `k8s/configmap.yaml` and set `BASE_URL` to your in-cluster service (e.g., `http://motel-api.default.svc.cluster.local:8085`).
    * Apply the manifest files:
        ```bash
        kubectl apply -f k8s/namespace.yaml
        kubectl -n motel-traffic apply -f k8s/configmap.yaml
        kubectl -n motel-traffic apply -f k8s/secret-sample.yaml
        ```

3.  **Deploy the CronJob:**
    * Deploy the `cronjob-ping.yaml` file, which runs once per minute. The container inside will perform one request per second for 60 seconds.
    ```bash
    # Update the image reference in the YAML if you pushed to a registry
    kubectl -n motel-traffic apply -f k8s/cronjob-ping.yaml
    kubectl -n motel-traffic get cronjobs
    ```

4.  **Monitor logs:**
    * **Watch for new jobs:** `kubectl -n motel-traffic get jobs --watch`
    * **Get the latest pod:**
        ```bash
        LATEST_POD=$(kubectl -n motel-traffic get pods -o jsonpath='{.items[-1:].metadata.name}')
        ```
    * **Tail the logs:** `kubectl -n motel-traffic logs -f "$LATEST_POD"`

---

## Extending the Framework

Adding your own traffic scenario is a straightforward process:

1.  **Create a new scenario file:** In `trafficgen/scenarios/`, add `<your_flow>.py` with a `run_once()` and an optional `run_loop_every_second()` function.
2.  **Add data generators (if needed):** If your scenario requires synthetic data, add a generator file to `trafficgen/data_generators/`.
3.  **Register the new task:** Update the `TASKS` dictionary in `trafficgen/run_task.py`.
4.  **Run it:** Use an existing CronJob YAML as a template, update the `TASK` environment variable, and deploy it to your cluster.

**Common Environment Variables:**
* `TASK`: The specific scenario to run (e.g., `ping_loop`).
* `BASE_URL`: The root URL of your API (no trailing slash).
* `DURATION_SECONDS`: How long loop scenarios should run.
* `API_TOKEN`: An optional bearer token for authentication.
* `LOG_LEVEL`: Set to `INFO` or `DEBUG`.
* `CONNECT_TIMEOUT`/`READ_TIMEOUT`: Timeouts in seconds for HTTP requests.

---

## Future Ideas

* **Traffic Shaping:** Implement more advanced traffic patterns, such as RPS caps, open/closed-loop scenarios, and weighted mixes of different flows.
* **Declarative Profiles:** Use a YAML file to describe endpoints, weights, and payload generators instead of hard-coding them.
* **Metrics Integration:** Export Prometheus metrics (e.g., latency histograms, error rates) in addition to the JSON logs.
* **Distributed Runs:** Run parallel jobs with shard-aware payload generators for large-scale tests.
* **CI Hooks:** Integrate the framework into a CI/CD pipeline to run smoke or end-to-end tests on every deployment.

---

## Notes
* **JSON logs** are emitted to `stdout`, which is ideal for log collectors like ELK, Loki, or CloudWatch.
* The `httpx` client uses **exponential backoff** for transient failures.
* Remember: `localhost` inside a container is not the same as your host machine. Use `host.docker.internal` or a Kubernetes Service DNS name.
