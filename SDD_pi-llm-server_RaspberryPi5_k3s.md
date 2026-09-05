# Spec-Driven Development (SDD) — pi-llm-server

**LLM local optimizado para Raspberry Pi 5 (8 GB) sobre k3s/Kubernetes, Longhorn, Istio y Argo CD**


> Estado actual: el Deployment usa la imagen oficial de llama.cpp y descarga con initContainer. Los ejemplos de imagen personalizada y Gateway dedicado son referencias de diseño; los manifiestos de kubernetes/base y el README describen la ruta activa mediante istio-system/kdvops-gateway. Los límites de memoria se conservan hasta medir el modelo en el nodo.

## 1. Objetivo

Diseñar y desplegar un servicio de inferencia LLM local, ligero y reproducible para una Raspberry Pi 5 ARM64 con 8 GB de RAM, ejecutado en k3s/Kubernetes y administrado con GitOps mediante Argo CD.

El servicio debe:
- usar un modelo cuantizado GGUF;
- minimizar el uso de RAM;
- mantener mmap habilitado y mlock deshabilitado;
- exponer una API compatible con OpenAI;
- persistir el modelo en un PVC Longhorn;
- publicarse mediante Istio Gateway + VirtualService;
- ejecutarse con una sola réplica;
- evitar descargar el modelo en cada reinicio;
- permitir que Hermes, OpenClaw, n8n u otros clientes compartan una sola instancia del modelo.


## 2. Decisión de modelo

Baseline recomendado:
- Repositorio: Qwen/Qwen2.5-Coder-3B-Instruct-GGUF
- Cuantización: Q4_K_M
- Formato: GGUF
- Runtime: llama.cpp
- Arquitectura: linux/arm64
- Contexto inicial: 4096 tokens
- Paralelismo: 1
- Threads: 4

Justificación:
Qwen2.5-Coder-3B-Instruct Q4_K_M es el candidato inicial para programación local; su latencia y consumo deben validarse en la Raspberry Pi con las demás cargas activas. La cuantización Q4 reduce el tamaño del modelo y llama.cpp permite memory mapping del archivo GGUF para evitar una copia completa adicional del modelo en memoria.


## 3. Requisitos funcionales

FR-001. El servicio debe exponer /v1/chat/completions mediante HTTP.
FR-002. El servicio debe ser compatible con clientes que esperen una API estilo OpenAI.
FR-003. El modelo debe persistir en un PVC Longhorn.
FR-004. El Pod debe reutilizar el modelo existente después de reinicios.
FR-005. El modelo debe descargarse mediante un initContainer del Deployment antes de iniciar el servidor.
FR-006. Argo CD debe gestionar los manifiestos declarativamente.
FR-007. Istio debe publicar el servicio mediante Gateway + VirtualService.
FR-008. El Service de Kubernetes debe ser ClusterIP.
FR-009. El Deployment debe usar replicas: 1.
FR-010. El Deployment debe usar strategy: Recreate.


## 4. Requisitos no funcionales

NFR-001. Arquitectura objetivo: Raspberry Pi 5 ARM64.
NFR-002. RAM física disponible: 8 GB compartidos con Linux, k3s y otros componentes.
NFR-003. El LLM debe usar GGUF cuantizado.
NFR-004. mmap debe permanecer habilitado.
NFR-005. mlock debe permanecer deshabilitado.
NFR-006. El límite inicial de memoria del Pod será 3500Mi.
NFR-007. El request inicial de memoria será 1800Mi.
NFR-008. CPU request: 500m; CPU limit: 4 cores.
NFR-009. Contexto inicial: 4096 tokens.
NFR-010. Paralelismo: 1.
NFR-011. El sidecar Envoy de Istio debe estar deshabilitado para ahorrar RAM, salvo necesidad explícita de mesh interno.
NFR-012. El volumen del modelo puede configurarse con una sola réplica Longhorn porque el modelo es reconstruible/descargable.


## 5. Arquitectura objetivo

Flujo lógico:

Cliente (Hermes / OpenClaw / n8n)
        |
        v
Istio IngressGateway
        |
        v
Gateway
        |
        v
VirtualService
        |
        v
Service ClusterIP :8080
        |
        v
Deployment llama.cpp (1 replica)
        |
        v
/mnt o /models/model.gguf
        |
        v
PVC Longhorn


## 6. Estructura del repositorio

pi-llm-server/
├── Dockerfile
├── README.md
├── scripts/
│   └── entrypoint.sh
└── kubernetes/
    ├── base/
    │   ├── namespace.yaml
    │   ├── pvc.yaml
    │   ├── configmap.yaml
    │   ├── model-download-job.yaml
    │   ├── deployment.yaml
    │   ├── service.yaml
    │   ├── gateway.yaml
    │   ├── virtualservice.yaml
    │   └── kustomization.yaml
    └── argocd/
        └── application.yaml


## 7. Dockerfile

```dockerfile
FROM debian:bookworm-slim AS builder

ARG LLAMA_CPP_REF=master

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git cmake build-essential ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN git clone --depth 1 --branch ${LLAMA_CPP_REF} \
    https://github.com/ggml-org/llama.cpp.git

WORKDIR /src/llama.cpp

RUN cmake -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DGGML_NATIVE=OFF \
      -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod && \
    cmake --build build --config Release -j4 --target llama-server

FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates curl libgomp1 && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder \
  /src/llama.cpp/build/bin/llama-server \
  /usr/local/bin/llama-server

COPY scripts/entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh && \
    mkdir -p /models && \
    chown -R 10001:10001 /models

USER 10001:10001
EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
```

Nota: para producción, LLAMA_CPP_REF debe fijarse a un tag o commit validado; no dejar master.


## 8. Entrypoint

```sh
#!/bin/sh
set -eu

MODEL="${MODEL_PATH:-/models/qwen2.5-coder-3b-instruct-q4_k_m.gguf}"

if [ ! -f "${MODEL}" ]; then
  echo "ERROR: GGUF model not found: ${MODEL}"
  exit 1
fi

exec /usr/local/bin/llama-server \
  --model "${MODEL}" \
  --host 0.0.0.0 \
  --port 8080 \
  --ctx-size "${CTX_SIZE:-4096}" \
  --threads "${THREADS:-4}" \
  --threads-batch "${THREADS_BATCH:-4}" \
  --batch-size "${BATCH_SIZE:-256}" \
  --ubatch-size "${UBATCH_SIZE:-128}" \
  --parallel "${PARALLEL:-1}" \
  --cache-type-k "${CACHE_TYPE_K:-q8_0}" \
  --cache-type-v "${CACHE_TYPE_V:-q8_0}"
```

No usar --mlock.
No usar --no-mmap.


## 9. Namespace

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: local-ai
```


## 10. PVC Longhorn

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pi-llm-models
  namespace: local-ai
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 5Gi
```


## 11. ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: pi-llm-config
  namespace: local-ai
data:
  MODEL_PATH: /models/qwen2.5-coder-3b-instruct-q4_k_m.gguf
  CTX_SIZE: "4096"
  THREADS: "4"
  THREADS_BATCH: "4"
  BATCH_SIZE: "256"
  UBATCH_SIZE: "128"
  PARALLEL: "1"
  CACHE_TYPE_K: "q8_0"
  CACHE_TYPE_V: "q8_0"
```


## 12. Descarga del modelo

La descarga del modelo se ejecuta como `initContainer` dentro del `Deployment` para evitar conflictos de `ReadWriteOnce` con el PVC.

```yaml
initContainers:
  - name: model-download
    image: curlimages/curl:8.10.1
    imagePullPolicy: IfNotPresent
    command: ["sh", "-c"]
    args:
      - |
        set -eu
        FILE="${MODEL_PATH:-/models/qwen2.5-coder-3b-instruct-q4_k_m.gguf}"
        URL="${MODEL_URL:-https://huggingface.co/Qwen/Qwen2.5-Coder-3B-Instruct-GGUF/resolve/main/qwen2.5-coder-3b-instruct-q4_k_m.gguf}"
        if [ -s "$FILE" ]; then
          echo "Model already exists: $FILE"
          exit 0
        fi
        tmp="${FILE}.part"
        mkdir -p "$(dirname "$tmp")"
        touch "$tmp"
        curl -L --fail --retry 20 --retry-delay 10 --retry-all-errors \
          --connect-timeout 30 \
          --speed-limit 1024 --speed-time 120 \
          -C - \
          -o "$tmp" "$URL"
        mv "$tmp" "$FILE"
    securityContext:
      allowPrivilegeEscalation: false
      runAsUser: 0
      runAsGroup: 0
    envFrom:
      - configMapRef:
          name: pi-llm-config
    volumeMounts:
      - name: models
        mountPath: /models
```

## 13. Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pi-llm
  namespace: local-ai
  annotations:
    argocd.argoproj.io/sync-wave: "3"
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: pi-llm
  template:
    metadata:
      labels:
        app: pi-llm
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      terminationGracePeriodSeconds: 30
      securityContext:
        fsGroup: 10001
        fsGroupChangePolicy: OnRootMismatch
      initContainers:
        - name: model-download
          image: curlimages/curl:8.10.1
          imagePullPolicy: IfNotPresent
          command: ["sh", "-c"]
          args:
            - |
              set -eu
              FILE="${MODEL_PATH:-/models/qwen2.5-coder-3b-instruct-q4_k_m.gguf}"
              URL="${MODEL_URL:-https://huggingface.co/Qwen/Qwen2.5-Coder-3B-Instruct-GGUF/resolve/main/qwen2.5-coder-3b-instruct-q4_k_m.gguf}"
              if [ -s "$FILE" ]; then
                echo "Model already exists: $FILE"
                exit 0
              fi
              tmp="${FILE}.part"
              mkdir -p "$(dirname "$tmp")"
              touch "$tmp"
              curl -L --fail --retry 20 --retry-delay 10 --retry-all-errors \
                --connect-timeout 30 \
                --speed-limit 1024 --speed-time 120 \
                -C - \
                -o "$tmp" "$URL"
              mv "$tmp" "$FILE"
          securityContext:
            allowPrivilegeEscalation: false
            runAsUser: 0
            runAsGroup: 0
          envFrom:
            - configMapRef:
                name: pi-llm-config
          volumeMounts:
            - name: models
              mountPath: /models
      containers:
        - name: llama-server
          image: ghcr.io/ggml-org/llama.cpp:server
          imagePullPolicy: IfNotPresent
          envFrom:
            - configMapRef:
                name: pi-llm-config
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          resources:
            requests:
              cpu: "500m"
              memory: 1800Mi
            limits:
              cpu: "4"
              memory: 3500Mi
          volumeMounts:
            - name: models
              mountPath: /models
          startupProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 10
            failureThreshold: 30
            timeoutSeconds: 5
          readinessProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 30
            timeoutSeconds: 5
            failureThreshold: 3
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            runAsGroup: 10001
            capabilities:
              drop:
                - ALL
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: pi-llm-models
```


## 14. Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: pi-llm
  namespace: local-ai
spec:
  type: ClusterIP
  selector:
    app: pi-llm
  ports:
    - name: http
      port: 8080
      targetPort: http
      protocol: TCP
```


## 15. Istio Gateway

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: pi-llm
  namespace: local-ai
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - llm.kdvops.com
```


## 16. Istio VirtualService

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: pi-llm
  namespace: local-ai
spec:
  hosts:
    - llm.kdvops.com
  gateways:
    - pi-llm
  http:
    - route:
        - destination:
            host: pi-llm.local-ai.svc.cluster.local
            port:
              number: 8080
      timeout: 300s
```


## 17. Kustomization

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - pvc.yaml
  - configmap.yaml
  - deployment.yaml
  - service.yaml
  - gateway.yaml
  - virtualservice.yaml
```


## 18. Argo CD Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: pi-llm
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/kdvops/LLM.git
    targetRevision: main
    path: kubernetes/base
  destination:
    server: https://kubernetes.default.svc
    namespace: local-ai
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```


## 19. Orden de sincronización Argo CD

Wave 0: Namespace
Wave 1: PVC
Wave 2: Sin recursos activos; el Job legado está excluido de Kustomize
Wave 3: Deployment con initContainer de descarga
Wave 4: Service, Gateway y VirtualService

El objetivo es que el modelo esté disponible antes de iniciar llama-server.


## 20. Gestión de memoria

Principios:
- GGUF cuantizado Q4.
- mmap habilitado por defecto.
- mlock deshabilitado.
- contexto inicial limitado a 4096.
- parallel=1.
- sidecar Istio deshabilitado.
- una sola réplica.
- evitar swap como estrategia normal.
- medir RSS, peak memory, prompt-eval y tokens/s antes de aumentar contexto.

Métricas/diagnóstico:
kubectl top pod -n local-ai
free -h
vmstat 1
pidstat -r 1


## 21. Criterios de aceptación

SDD-001 — ARM64
Given una Raspberry Pi 5 ARM64
When el contenedor inicia
Then llama-server debe arrancar correctamente.

SDD-002 — Memoria
Given 8 GB de RAM física
When el modelo está cargado y responde
Then el Pod debe permanecer por debajo del límite configurado de 3500Mi.

SDD-003 — Persistencia
Given un reinicio del Pod
When se crea el nuevo Pod
Then el archivo GGUF debe seguir disponible en el PVC.

SDD-004 — mmap
Given llama-server
When se inicia
Then mmap debe permanecer habilitado
And mlock debe permanecer deshabilitado.

SDD-005 — API
Given un cliente HTTP
When realiza POST /v1/chat/completions
Then debe recibir una respuesta válida del modelo.

SDD-006 — Kubernetes
replicas = 1
strategy = Recreate
Service = ClusterIP
PVC = Longhorn RWO.

SDD-007 — Istio
Given el host llm.kdvops.com
When llega una petición al Gateway
Then debe enrutar a pi-llm:8080.

SDD-008 — GitOps
Given un cambio declarativo en Git
When Argo CD sincroniza
Then el estado del cluster debe converger al estado deseado.

SDD-009 — Recuperación
Given la eliminación manual del Pod
When Kubernetes lo recrea
Then no debe perderse el modelo persistido.


## 22. Benchmark recomendado

Comparar, si están disponibles para el mismo modelo:
- Q3_K_M
- Q4_K_M
- Q4_K_M
- Q5_K_M

Medir:
- tokens/s de generación;
- prompt-eval tokens/s;
- time-to-first-token;
- RSS y peak memory;
- temperatura del SoC;
- throttling;
- lecturas de disco;
- estabilidad durante 30 minutos;
- latencia con contexto 4K y 8K.

Criterio de selección:
usar la cuantización con mejor equilibrio entre calidad, memoria y throughput sostenido, no necesariamente la de menor tamaño.


## 23. Configuración baseline v1.0

Modelo: Qwen2.5-Coder-3B-Instruct
Formato: GGUF
Quant: Q4_K_M
Runtime: llama.cpp
Arquitectura: linux/arm64
Contexto: 4096
Threads: 4
Parallel: 1
Request CPU: 500m
Limit CPU: 4
Request RAM: 1800Mi
Limit RAM: 3500Mi
PVC: Longhorn 5Gi RWO
Replicas Deployment: 1
Strategy: Recreate
Service: ClusterIP :8080
Istio sidecar: disabled
Ingress: Istio Gateway + VirtualService
GitOps: Argo CD


## 24. Mejoras posteriores

- TLS en el Istio Gateway.
- AuthorizationPolicy para restringir clientes.
- API key o autenticación delante de llama-server.
- NetworkPolicy.
- PodDisruptionBudget si se mueve a varios nodos.
- checksum del GGUF antes de iniciar.
- Pin del digest de la imagen.
- SBOM y firma Cosign del contenedor.
- métricas Prometheus.
- dashboard Grafana con uso CPU/RAM, tokens/s y temperatura.
- benchmark automatizado al cambiar de versión del modelo.
- opción de overlay Kustomize para 4K/8K de contexto.
