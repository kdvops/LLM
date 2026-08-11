# agents.md

## Repository
- Name: LLM
- Repo path: /opt/data/workspace/LLM
- Remote: https://github.com/kdvops/LLM.git
- Default branch: main

## Purpose
- What this application does: GitOps repository for a Raspberry Pi 5 ARM64 local LLM service based on llama.cpp, GGUF quantization, Longhorn persistence, and Istio exposure.
- Primary users: Kelvin and internal clients such as Hermes, OpenClaw, n8n, and other shared OpenAI-compatible consumers.
- Business/domain context: lightweight local inference for the kdvops k3s cluster.

## Stack
- Language(s): YAML, shell, Dockerfile syntax, Markdown
- Framework(s): Kubernetes, Kustomize, Argo CD, Istio, llama.cpp
- Package manager / build system: Docker multi-stage build with CMake inside the container build
- Runtime / base image: debian:bookworm-slim
- OS / architecture assumptions: linux/arm64 on Raspberry Pi 5; model runtime designed for 8 GB RAM

## Deployment
- Platforms: k3s / Kubernetes
- Orchestration: Argo CD GitOps, Longhorn persistent volume, Istio Gateway + VirtualService
- CI/CD: declarative repo-managed manifests; no pipeline files are present yet
- Ingress / routing: Istio Gateway host llm.kdvops.local routed to pi-llm service on port 8080
- Services / dependencies: Longhorn storage, Istio ingress gateway, Hugging Face model download source, llama.cpp server

## Bootstrap
- Install: clone repo and ensure Docker/build tooling plus kubectl access to the target cluster
- Build: docker build -t ghcr.io/kdvops/pi-llm:1.0.0 .
- Run: container expects a GGUF model mounted or present at MODEL_PATH
- Test: curl http://<service-host>/v1/models or POST /v1/chat/completions once deployed
- Lint: validate YAML manifests before apply/sync
- Migrations / seed: none

## Configuration
- Main config files: Dockerfile, scripts/entrypoint.sh, kubernetes/base/*.yaml, kubernetes/argocd/application.yaml
- Environment variables: MODEL_PATH, MODEL_URL, CTX_SIZE, THREADS, THREADS_BATCH, BATCH_SIZE, UBATCH_SIZE, PARALLEL, CACHE_TYPE_K, CACHE_TYPE_V
- Feature flags: Istio sidecar disabled via annotation; model download is idempotent
- ConfigMaps / mounted files: pi-llm-config ConfigMap; model PVC mounted at /models

## Secrets and credential locations
- DB credentials: none
- App users / auth: none defined in this repository
- Git credentials: GitHub access via the user's local git/gh auth if publishing changes
- Cloud credentials: none stored in repo; cluster access is assumed through local kubeconfig
- Secret manager / vault refs: none in current manifests

## Data and storage
- PVCs / volumes: pi-llm-models PVC using Longhorn, 5Gi, ReadWriteOnce
- Databases: none
- Object storage: none
- Backups / restore notes: the GGUF model is reconstructible by re-running the download Job

## Operational notes
- Known pitfalls: keep mmap enabled and avoid mlock; the model file must exist before llama-server starts; the deployment is intentionally single-replica with Recreate strategy
- Health checks: /health on port 8080
- Rollout expectations: Argo CD sync waves should bring up namespace, PVC, download Job, then the Deployment, then service/routing objects
- Architecture / platform notes: optimized for Raspberry Pi 5 ARM64 with 8 GB RAM and a quantized GGUF model

## Verification
- Commands to confirm the app is healthy: kubectl get pods -n local-ai; kubectl logs deploy/pi-llm -n local-ai; curl http://llm.kdvops.local/health
- Commands to confirm deployment state: kubectl get pvc,job,deploy,svc,gateway,virtualservice -n local-ai
- Commands to confirm the repo is in sync: git status --short --branch; git branch -vv
