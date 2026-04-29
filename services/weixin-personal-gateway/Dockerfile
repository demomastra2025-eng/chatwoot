FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY pyproject.toml ./
COPY weixin_gateway ./weixin_gateway

RUN adduser --disabled-password --gecos "" --home /app --uid 10001 weixin \
  && chown -R weixin:weixin /app

USER weixin

EXPOSE 8097

CMD ["python", "-m", "weixin_gateway.server"]
