# runpod-ocrpod

vLLM (serving the [olmOCR-2](https://huggingface.co/allenai/olmOCR-2-7B-1025-FP8) OCR model)
with [Tailscale](https://tailscale.com/) built in, for [RunPod](https://runpod.io/) pods.

The container joins your tailnet on boot, exposes vLLM's OpenAI-compatible API
over the tailnet via `tailscale serve` (HTTPS, no public ports, no port
mapping needed on the RunPod side), then starts `vllm serve` with whatever
model args the RunPod template passes as the container command.

## Required environment variables

| Variable | Required | Default | Notes |
| --- | --- | --- | --- |
| `TS_AUTHKEY` | yes (or `RUNPOD_SECRET_TSAUTH_KEY`) | — | Tailscale auth key. Generate a fresh ephemeral key per run. |
| `TS_HOSTNAME` | no | `runpod-olmocr` | Base hostname to register on the tailnet. |
| `TS_ADMIN_AUTHKEY` | no (or `RUNPOD_SECRET_TSADMINAUTH_KEY`) | — | Tailscale admin API key. When set, the entrypoint deletes stale nodes still holding `TS_HOSTNAME` from a previous run before re-registering, so you always get the clean hostname instead of a `-2`/`-3` suffix. |
| `VLLM_PORT` | no | `8000` | Port `tailscale serve` proxies to. Must match the `--port` value in the container command. |
| `VLLM_API_KEY` | no | — | Set by vLLM itself (pass `--api-key` in the container command, or vLLM reads this env var) to require a bearer token on API requests. Not read by the entrypoint. |

## Example RunPod container command

Set this as the pod/template's container command (the image's `ENTRYPOINT` is
the Tailscale bootstrap script; these args are passed straight through to
`vllm serve`):

```
allenai/olmOCR-2-7B-1025-FP8 --served-model-name olmocr --max-model-len 16384 --gpu-memory-utilization 0.90 --host 0.0.0.0 --port 8000
```

Once the pod is up and joins the tailnet, the API is reachable at:

```
https://runpod-olmocr.<tailnet>.ts.net/v1
```

(substitute your actual tailnet name and `TS_HOSTNAME`, if changed).

## Manual one-time step after the first workflow run

GHCR packages pushed via the workflow's `GITHUB_TOKEN` default to **private**
— the token can't change package visibility itself. Go to the repo's Packages
tab (or `github.com/users/<owner>/packages/container/<repo>/settings`) and set
the package visibility to Public if you want the image pullable without
authentication.
