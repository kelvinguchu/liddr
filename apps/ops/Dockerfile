# syntax=docker/dockerfile:1
# The Liddr staff console: build with Node 24, run the self-contained Nitro
# server (.output) on a slim Node 24 image as the unprivileged node user.
# It holds no secrets: the API sets and reads the session cookies.
FROM node:24-bookworm-slim AS build
WORKDIR /src
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
RUN npm run build

FROM node:24-bookworm-slim AS runtime
ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=3000
WORKDIR /srv/liddr-ops
COPY --from=build --chown=node:node /src/.output ./.output
USER node
EXPOSE 3000
CMD ["node", ".output/server/index.mjs"]
