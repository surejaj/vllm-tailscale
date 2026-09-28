# Pinned — do NOT switch to a "-cu129" tag: those ship a torch/torchvision
# mismatch that crashes at inference with "torchvision::nms does not exist".
FROM vllm/vllm-openai:v0.30.0

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates jq \
    && curl -fsSL https://tailscale.com/install.sh | sh \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
