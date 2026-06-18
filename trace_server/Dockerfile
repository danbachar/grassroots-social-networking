FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY server.py .

# Persist the archive + SQLite DB on a mounted volume.
ENV TRACE_DATA_DIR=/app/data
VOLUME ["/app/data"]

EXPOSE 8443

# TRACE_UPLOAD_TOKEN must be provided at runtime (-e TRACE_UPLOAD_TOKEN=...).
CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8443"]
