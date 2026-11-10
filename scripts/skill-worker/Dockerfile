# Official Docker Hub library/python index, verified 2026-11-10 via registry-1.docker.io.
# linux/amd64 manifest: sha256:05a994d2344eb364cc186910f4fc8786a38215f39f00d0acc25bff33a08f4177
FROM python:3.12.16-slim-trixie@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b
WORKDIR /opt/worker
COPY requirements.txt ./
RUN pip install --no-cache-dir --require-hashes -r requirements.txt
COPY worker.py ./
COPY vendor ./vendor
USER 65534:65534
ENTRYPOINT ["python", "-I", "/opt/worker/worker.py"]
