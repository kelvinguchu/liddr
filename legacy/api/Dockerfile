# syntax=docker/dockerfile:1.7

FROM golang:1.25.2-bookworm AS s2cover_builder

WORKDIR /src

COPY native/s2cover/go.mod native/s2cover/go.sum ./
RUN go mod download

COPY native/s2cover ./
RUN CGO_ENABLED=0 go build -o /out/s2cover .

FROM elixir:1.17.3-otp-27 AS builder

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends build-essential git && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config

RUN mix deps.get --only prod
RUN mix deps.compile

COPY lib lib
COPY priv priv
COPY --from=s2cover_builder /out/s2cover priv/bin/s2cover

RUN mix compile
RUN mix liddr.security.prod_guard
RUN mix release

FROM debian:bookworm-slim AS runtime

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      libstdc++6 \
      openssl \
      libncurses6 \
      locales \
      ca-certificates \
      curl && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && \
    locale-gen && \
    rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
ENV HOME=/app

WORKDIR /app

RUN useradd --system --uid 1001 --create-home --home-dir /app app

COPY --from=builder --chown=app:app /app/_build/prod/rel/liddr ./
COPY --chown=app:app docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER app

EXPOSE 4000

ENTRYPOINT ["/entrypoint.sh"]
