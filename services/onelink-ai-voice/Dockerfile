FROM node:lts-alpine

ARG SOURCE_SHA
LABEL org.opencontainers.image.revision=$SOURCE_SHA

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY src ./src
RUN test -n "$SOURCE_SHA" && printf '%s\n' "$SOURCE_SHA" > /app/.git_sha
CMD ["npm", "start"]
