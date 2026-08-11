# LLM

GitOps repository for a lightweight local LLM service on Raspberry Pi 5 / k3s.

## What is here

This repo implements the SDD for `pi-llm-server`:

- `llama.cpp` server container for ARM64
- GGUF model stored on Longhorn PVC
- Kubernetes manifests under `kubernetes/base`
- Argo CD application manifest under `kubernetes/argocd`

## Topology

`Client -> Istio Gateway -> VirtualService -> ClusterIP Service -> Deployment -> PVC`

The deployment is intentionally:

- single replica
- `Recreate` strategy
- Istio sidecar disabled
- model downloaded by a separate Job

## Repository layout

```text
Dockerfile
README.md
agents.md
scripts/entrypoint.sh
kubernetes/
  base/
  argocd/
```

## Baseline model

- Repository: `unsloth/Qwen3.5-2B-GGUF`
- Quantization: `UD-Q4_K_XL`
- Context: `4096`
- Threads: `4`
- Parallel: `1`

## Build

```bash
docker build -t ghcr.io/kdvops/pi-llm:1.0.0 .
```

If you want to pin `llama.cpp` to a specific validated tag/commit, pass:

```bash
docker build --build-arg LLAMA_CPP_REF=<tag-or-commit> -t ghcr.io/kdvops/pi-llm:1.0.0 .
```

## Deploy

Apply or let Argo CD sync the manifests:

```bash
kubectl apply -k kubernetes/base
kubectl apply -f kubernetes/argocd/application.yaml
```

> The Argo CD Application currently points to this repository URL.

## Verify

```bash
kubectl get ns local-ai
kubectl get pvc,job,deploy,svc,gateway,virtualservice -n local-ai
kubectl logs job/pi-llm-model-download -n local-ai
kubectl logs deploy/pi-llm -n local-ai
curl http://llm.kdvops.local/health
curl http://llm.kdvops.local/v1/models
```

## Notes

- `MODEL_PATH` must match the downloaded GGUF filename.
- The Pod expects the model to already exist on the PVC before the server starts.
- Keep `mmap` enabled and `mlock` disabled.
- If your cluster uses a different Istio ingress gateway selector, adjust `kubernetes/base/gateway.yaml` accordingly.
