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
- model downloaded by an init container before the server starts

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

- Repository: `Qwen/Qwen2.5-Coder-3B-Instruct-GGUF`
- File: `qwen2.5-coder-3b-instruct-q4_k_m.gguf` (approximately 2.10 GB)
- Quantization: `Q4_K_M`
- Context: `4096`
- Threads: `4`
- Parallel: `1`

## Build

The Kubernetes deployment uses `ghcr.io/ggml-org/llama.cpp:server` and defines its command directly. The Dockerfile and entrypoint below are an optional custom-image path; building them does not change the deployed image. Pin the deployed image to a validated ARM64 digest before relying on reproducible rollouts.

```bash
docker build -t ghcr.io/kdvops/pi-llm:1.0.0 .
```

If you want to pin the custom build to a validated release tag, pass:

```bash
docker build --build-arg LLAMA_CPP_REF=<release-tag> -t ghcr.io/kdvops/pi-llm:1.0.0 .
```

## Deploy

Apply or let Argo CD sync the manifests:

```bash
kubectl apply -k kubernetes/base
kubectl apply -f kubernetes/argocd/application.yaml
```

> The Argo CD Application currently points to this repository URL.

Argo CD tracks `main`. This model migration changes the Deployment command, so syncing it recreates the Pod automatically. For later ConfigMap-only changes, restart the Deployment after syncing because environment variables are read at Pod creation:

```bash
kubectl rollout restart deployment/pi-llm -n local-ai
kubectl rollout status deployment/pi-llm -n local-ai --timeout=20m
```

The 5Gi PVC fits the new model individually. Check free space before migration if the previous model is present; downloads keep existing files and use a `.part` file until complete. Do not delete the PVC to switch models.

## Verify

```bash
kubectl get ns local-ai
kubectl get pvc,deploy,svc,gateway,virtualservice -n local-ai
kubectl logs deploy/pi-llm -n local-ai -c model-download
kubectl logs deploy/pi-llm -n local-ai -c llama-server
kubectl top pod -n local-ai
curl http://llm.kdvops.com/health
curl http://llm.kdvops.com/v1/models
```

For an in-cluster client, use `http://pi-llm.local-ai.svc.cluster.local:8080/v1`. For an editor outside the cluster, use the configured ingress scheme and `llm.kdvops.com/v1`; the shared gateway determines TLS. Use the model ID returned by `/v1/models` in `/v1/chat/completions`.

Start with short coding requests and compare generated code against actual tests. Measure time to first token, generation speed and peak memory with the other node workloads running. The 4096-token context includes instructions, history, code and output. The existing `1800Mi` memory request and `3500Mi` limit are retained pending measurements; the request is a scheduling reservation, not a consumption estimate. If memory approaches the limit, assess node capacity before increasing it, or evaluate the 1.5B alternative.

## Notes

- `MODEL_PATH` must match the downloaded GGUF filename.
- The init container downloads the model only when its target file is absent or empty. The standalone download Job is a legacy file excluded from Kustomize; do not run both download mechanisms together.
- Keep `mmap` enabled and `mlock` disabled.
- The VirtualService references the existing `istio-system/kdvops-gateway`. The separate `pi-llm` Gateway in this repository is not referenced by that route. Confirm the shared gateway accepts `llm.kdvops.com`.
