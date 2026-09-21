# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t miniscrap .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> \
#   -e FLARESOLVERR_URL=http://<flaresolverr-host>:8191 --name miniscrap miniscrap
#
# The image carries curl-impersonate (the fast path). FlareSolverr (the slow
# path's browser) runs as its own container — a Kamal accessory in production.

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=3.4.9
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# curl-impersonate: the fast path's real-Chrome TLS/HTTP-2 client. Pinned by
# version AND checksum — its Chrome profiles must stay close to FlareSolverr's
# Chromium (the clearance is bound to the TLS fingerprint), so an upgrade is a
# deliberate change, never a silent `latest`. x86_64 only (builder.arch: amd64).
FROM base AS curl_impersonate
ARG CURL_IMPERSONATE_VERSION=v1.5.6
ARG CURL_IMPERSONATE_SHA256=b60344f63b9ed8806f0e9f7fd357d9f6c9a82aca279ed1e9e257d544885dcbde
RUN curl -fsSL -o /tmp/curl-impersonate.tar.gz \
      "https://github.com/lexiforest/curl-impersonate/releases/download/${CURL_IMPERSONATE_VERSION}/curl-impersonate-${CURL_IMPERSONATE_VERSION}.x86_64-linux-gnu.tar.gz" && \
    echo "${CURL_IMPERSONATE_SHA256}  /tmp/curl-impersonate.tar.gz" | sha256sum -c - && \
    mkdir -p /opt/curl-impersonate && \
    tar xzf /tmp/curl-impersonate.tar.gz -C /opt/curl-impersonate curl-impersonate && \
    rm /tmp/curl-impersonate.tar.gz

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libvips libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY vendor/* ./vendor/
COPY Gemfile Gemfile.lock ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Copy application code
COPY . .

# Precompile bootsnap code for faster boot times.
# -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
RUN bundle exec bootsnap precompile -j 1 app/ lib/




# Final stage for app image
FROM base

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

# Copy built artifacts: gems, application, the curl-impersonate binary
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails
COPY --from=curl_impersonate /opt/curl-impersonate /opt/curl-impersonate

# CURL_IMPERSONATE_DIR: where the fast path finds its binary.
# HTTP_WRITE_TIMEOUT: Thruster's default (30s) would cut off a cold request
# whose browser solve runs to its deadline (60s solve + 10s grace).
# GZIP_COMPRESSION_ENABLED: Thruster gzips text/event-stream too, and gzip
# buffers it — the ?stream=true events would arrive in one lump at the end
# (measured; `Cache-Control: no-transform` does not stop it). JSON bodies are
# small, so compression is off; do it at an outer proxy that understands SSE.
ENV CURL_IMPERSONATE_DIR="/opt/curl-impersonate" \
    HTTP_WRITE_TIMEOUT="90" \
    GZIP_COMPRESSION_ENABLED="false"

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
