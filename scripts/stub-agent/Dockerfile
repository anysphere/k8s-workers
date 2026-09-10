# Stub worker/controller image for scripts/kind-e2e.sh. `kubectl` is copied
# out of the kind node by the script so it matches the cluster version.
FROM python:3.12-slim
COPY kubectl /usr/local/bin/kubectl
COPY agent /usr/local/bin/agent
RUN chmod 755 /usr/local/bin/kubectl /usr/local/bin/agent && mkdir -p /workspace
WORKDIR /workspace
