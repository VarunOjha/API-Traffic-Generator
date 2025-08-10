FROM python:3.12-slim

WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN pip install --no-cache-dir --upgrade pip
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY api-traffic-generator ./api-traffic-generator

# Default command (override TASK, BASE_URL, etc. via env)
ENV TASK=post_motel_chain \
    BASE_URL=http://localhost:8085 \
    LOG_LEVEL=INFO \
    DURATION_SECONDS=60

CMD ["python", "-m", "api-traffic-generator.run_task"]
