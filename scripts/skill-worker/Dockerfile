FROM python:3.12-slim
WORKDIR /opt/worker
COPY requirements.txt ./
RUN pip install --no-cache-dir --require-hashes -r requirements.txt
COPY worker.py ./
COPY vendor ./vendor
USER 65534:65534
ENTRYPOINT ["python", "-I", "/opt/worker/worker.py"]
