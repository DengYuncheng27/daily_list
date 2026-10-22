FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 \
    DAYFLOW_DATABASE_PATH=/data/dayflow.sqlite3 \
    DAYFLOW_ATTACHMENT_DIRECTORY=/data/attachments
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir --disable-pip-version-check -r requirements.txt \
    && groupadd --gid 10001 dayflow \
    && useradd --uid 10001 --gid dayflow --no-create-home dayflow \
    && mkdir -p /data && chown dayflow:dayflow /data && chmod 700 /data
COPY dayflow ./dayflow
USER 10001:10001
VOLUME ["/data"]
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/api/v1/health', timeout=3)"]
CMD ["uvicorn", "dayflow.main:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--no-proxy-headers", "--no-access-log"]
