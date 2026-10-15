# Backend gestito di Quaderno AI: API FastAPI + worker Swift (QuadernoCore).
# Build dalla radice del repository:
#   docker build -f Backend/Dockerfile -t quaderno-backend .

FROM swift:6.1-noble AS worker
WORKDIR /src
COPY Packages/QuadernoCore ./QuadernoCore
RUN cd QuadernoCore && swift build -c release --product quaderno-worker --static-swift-stdlib \
    && cp .build/release/quaderno-worker /usr/local/bin/quaderno-worker \
    && mkdir -p /opt/quaderno && cp -r .build/release/QuadernoCore_QuadernoCore.resources /opt/quaderno/ 2>/dev/null || true

FROM python:3.13-slim
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg libcurl4 libxml2 ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY Backend/app ./app
COPY --from=worker /usr/local/bin/quaderno-worker /usr/local/bin/quaderno-worker
COPY Packages/QuadernoCore/Sources/QuadernoCore/Resources/prompts /opt/quaderno/prompts
ENV QUADERNO_DATA_DIR=/data \
    QUADERNO_WORKER_BIN=/usr/local/bin/quaderno-worker \
    PROMPTS_DIR=/opt/quaderno/prompts
RUN useradd --system --create-home quaderno && mkdir -p /data && chown quaderno /data
USER quaderno
VOLUME ["/data"]
EXPOSE 8000
CMD ["uvicorn", "--factory", "app.main:create_app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers"]
