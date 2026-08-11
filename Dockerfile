FROM debian:bookworm-slim AS builder

ARG LLAMA_CPP_REF=master

RUN apt-get update &&         apt-get install -y --no-install-recommends           git cmake build-essential ca-certificates curl &&         rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN git clone --depth 1 --branch ${LLAMA_CPP_REF}         https://github.com/ggml-org/llama.cpp.git

WORKDIR /src/llama.cpp

RUN cmake -B build           -DCMAKE_BUILD_TYPE=Release           -DGGML_NATIVE=OFF           -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod &&         cmake --build build --config Release -j4 --target llama-server

FROM debian:bookworm-slim

RUN apt-get update &&         apt-get install -y --no-install-recommends           ca-certificates curl libgomp1 &&         rm -rf /var/lib/apt/lists/*

COPY --from=builder       /src/llama.cpp/build/bin/llama-server       /usr/local/bin/llama-server

COPY scripts/entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh &&         mkdir -p /models /tmp &&         chown -R 10001:10001 /models /tmp

USER 10001:10001
EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
