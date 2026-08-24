FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
WORKDIR /app
COPY pyproject.toml ./
COPY prompt_manifest.json ./
COPY couponcok_agent ./couponcok_agent
RUN pip install --no-cache-dir .
CMD ["sh", "-c", "uvicorn couponcok_agent.server:api --host 0.0.0.0 --port ${PORT:-8080}"]
