# Proves three things a real workshop image needs: the base image builds,
# pip works inside a build, and the running container can reach the APIs.
ARG BASE_IMAGE=python:3.12-slim
FROM ${BASE_IMAGE}
ARG PIP_INDEX_URL=https://pypi.org/simple
RUN pip install --no-cache-dir --disable-pip-version-check --index-url "${PIP_INDEX_URL}" requests
COPY probe.py /probe.py
ENTRYPOINT ["python", "/probe.py"]
