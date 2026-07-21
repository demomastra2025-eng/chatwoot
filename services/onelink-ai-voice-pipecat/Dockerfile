FROM python:3.11-slim AS runtime

COPY --from=ghcr.io/astral-sh/uv:0.11.6 /uv /uvx /bin/
WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_LINK_MODE=copy \
    NLTK_DATA=/app/nltk_data

RUN groupadd --system onelink && useradd --system --gid onelink --home /app onelink
COPY pyproject.toml uv.lock README.md ./
RUN uv sync --frozen --no-dev --no-install-project
RUN mkdir -p "$NLTK_DATA" \
    && /app/.venv/bin/python -m nltk.downloader -d "$NLTK_DATA" punkt_tab \
    && chown -R onelink:onelink "$NLTK_DATA"
COPY --chown=onelink:onelink app ./app
RUN uv sync --frozen --no-dev
COPY docker-entrypoint.sh /usr/local/bin/onelink-pipecat-entrypoint
RUN chmod 0755 /usr/local/bin/onelink-pipecat-entrypoint

USER root
EXPOSE 8084
ENTRYPOINT ["/usr/local/bin/onelink-pipecat-entrypoint"]
CMD ["/app/.venv/bin/uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8084"]
