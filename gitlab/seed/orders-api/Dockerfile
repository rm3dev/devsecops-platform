# orders-api - stdlib-only Python service.
# The base image is resolved through the platform's Nexus docker-proxy
# (BuildKit mirror config) - never docker.io directly.
FROM python:3.12-slim

WORKDIR /srv/orders-api
COPY app.py ./

ENV HTTP_PORT=8080 LOG_LEVEL=info
EXPOSE 8080

# Non-root; port 8080 is unprivileged so no capabilities needed.
USER 1000:1000

CMD ["python", "app.py"]
