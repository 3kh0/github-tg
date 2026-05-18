ARG RUBY_VERSION=4.0.4
FROM ruby:${RUBY_VERSION}-slim AS base

ENV BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test \
    LANG=C.UTF-8 \
    PORT=4567

WORKDIR /app

FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential && \
    rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock* ./
RUN bundle install && \
    rm -rf "${BUNDLE_PATH}"/ruby/*/cache

FROM base AS runtime

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y ca-certificates tini curl && \
    rm -rf /var/lib/apt/lists/* && \
    groupadd --system --gid 1000 app && \
    useradd  --system --uid 1000 --gid app --create-home app

COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --chown=app:app . .

USER app

EXPOSE 4567

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS http://127.0.0.1:${PORT:-4567}/health || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["sh", "-c", "bundle exec puma -p ${PORT:-4567} config.ru"]
