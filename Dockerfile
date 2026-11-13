# syntax=docker/dockerfile:1
# Node.js 24 is copied from the official image rather than installed from
# NodeSource's apt repository, which is about 65 MB smaller.
FROM node:24-slim AS node

# Testing image used for GitLab CI
FROM php:8.3-apache AS base

# Disbale npm lifecycle scripts.
ENV npm_config_ignore_scripts=true

# Node.js 24 with npm and npx (Yarn isn't copied).
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
    ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx && \
    ln -s ../lib/node_modules/corepack/dist/corepack.js /usr/local/bin/corepack

# Each layer that installs packages cleans up after itself: files deleted in a
# later layer still ship in the earlier one.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    libavif-dev \
    libsodium-dev \
    libpng-dev \
    libjpeg-dev \
    libfreetype6-dev \
    libicu-dev \
    libjpeg62-turbo-dev \
    libssl-dev \
    libcurl4-openssl-dev \
    libzip-dev \
    libonig-dev \
    libxml2-dev \
    libpq-dev \
    curl \
    jq \
    unzip \
    ca-certificates \
    sudo \
    git \
    postgresql-client \
    && apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /usr/share/doc/* /usr/share/man/*

# Configure GD with jpeg, freetype, and avif support, and install the PHP
# extensions required by Drupal. These share a layer because configuring
# unpacks the PHP source (~150 MB), which only the install step removes.
RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-avif && \
    docker-php-ext-install -j$(nproc) \
    sodium \
    pdo \
    pdo_mysql \
    pdo_pgsql \
    mysqli \
    gd \
    intl \
    opcache \
    zip \
    mbstring \
    xml \
    dom \
    simplexml && \
    rm -rf /tmp/* /var/tmp/*

COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Enable Apache mod_rewrite (if needed)
RUN a2enmod rewrite

# Set high limit for CLI (unlimited)
RUN echo "memory_limit = -1" > /usr/local/etc/php/conf.d/cli-memory.ini
# Set reasonable limit for Apache
RUN echo "memory_limit = 512M" > /usr/local/etc/php/conf.d/apache-memory.ini
RUN echo "post_max_size = 64M" > /usr/local/etc/php/conf.d/post-max-size.ini

# Used for PHPUnit functional tests.
RUN CHROME_VERSION=$(curl -s https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json | jq -r '.channels.Stable.version') && \
    curl -L "https://storage.googleapis.com/chrome-for-testing-public/${CHROME_VERSION}/linux64/chrome-linux64.zip" -o chrome-linux64.zip && \
    unzip chrome-linux64.zip -d /opt/ && \
    ln -sf /opt/chrome-linux64/chrome /usr/local/bin/google-chrome && \
    curl -L "https://storage.googleapis.com/chrome-for-testing-public/${CHROME_VERSION}/linux64/chromedriver-linux64.zip" -o chromedriver-linux64.zip && \
    unzip chromedriver-linux64.zip -d /usr/local/bin/ && \
    mv /usr/local/bin/chromedriver-linux64/chromedriver /usr/local/bin/ && \
    chmod +x /usr/local/bin/chromedriver && \
    rm -f chrome-linux64.zip chromedriver-linux64.zip && \
    rm -rf /usr/local/bin/chromedriver-linux64/

WORKDIR /var/www/html

# Playwright's OS dependencies for Chromium only (also enough for Chrome for
# Testing above).
FROM base AS chromium-deps
RUN npx playwright install-deps chromium && \
    rm -rf /root/.npm /var/lib/apt/lists/* /tmp/* /var/tmp/* /usr/share/doc/* /usr/share/man/*

# Builds Drupal Canvas (https://www.drupal.org/project/canvas) the way its CI
# does, to fill the caches the `canvas` target ships. Nothing else from this
# stage ends up in an image.
FROM chromium-deps AS canvas-build

COPY --from=mikefarah/yq:4.44.3 /usr/bin/yq /usr/local/bin/yq

ARG CANVAS_REPO=https://git.drupalcode.org/project/canvas.git
ARG CANVAS_REF=1.x
# Default to DRUPAL_CORE and DRUPAL_CORE_NEXT_MINOR from Canvas's .gitlab-ci.yml.
ARG DRUPAL_CORE=
ARG DRUPAL_CORE_NEXT_MINOR=

ENV CANVAS_CACHE_DIR=/opt/canvas-cache
ENV COMPOSER_CACHE_DIR=${CANVAS_CACHE_DIR}/composer \
    COMPOSER_HOME=${CANVAS_CACHE_DIR}/composer-home \
    npm_config_cache=${CANVAS_CACHE_DIR}/npm \
    TURBO_CACHE_DIR=${CANVAS_CACHE_DIR}/turbo \
    PLAYWRIGHT_BROWSERS_PATH=${CANVAS_CACHE_DIR}/ms-playwright \
    CYPRESS_CACHE_FOLDER=${CANVAS_CACHE_DIR}/cypress \
    COMPOSER_NO_BLOCKING=1 \
    COMPOSER_NO_SECURITY_BLOCKING=1 \
    COMPOSER_PROCESS_TIMEOUT=0 \
    COMPOSER_ALLOW_SUPERUSER=1 \
    TURBO_TELEMETRY_DISABLED=1

# BuildKit re-checks the remote ref on every build, so this layer (and those
# after it) rebuild whenever the Canvas branch moves.
ADD --keep-git-dir=true ${CANVAS_REPO}#${CANVAS_REF} /tmp/canvas-build/canvas

WORKDIR /tmp/canvas-build

RUN composer config --global cache-files-maxsize 2GiB

# Composer: mirror `.drupal-files-with-dev-dependencies` in Canvas's CI, once
# per core version that CI tests against. This runs before `npm ci` because the
# path repository copies the whole checkout, and node_modules would go with it.
RUN set -eu; \
    core=${DRUPAL_CORE:-$(yq '.variables.DRUPAL_CORE // ""' canvas/.gitlab-ci.yml)}; \
    next=${DRUPAL_CORE_NEXT_MINOR:-$(yq '.variables.DRUPAL_CORE_NEXT_MINOR // ""' canvas/.gitlab-ci.yml)}; \
    if [ -z "$core" ]; then echo "DRUPAL_CORE not found in Canvas's .gitlab-ci.yml" >&2; exit 1; fi; \
    if [ "$next" = "$core" ]; then next=; fi; \
    packages=$(jq -r '.["require-dev"] // {} | to_entries[] | "\(.key):\(.value)"' canvas/composer.json | tr '\n' ' '); \
    for version in $core $next; do \
      echo "Warming the Composer cache for Drupal core $version"; \
      composer create-project "drupal/recommended-project:$version" "_drupal-$version" --no-install --no-interaction; \
      cd "_drupal-$version"; \
      composer config minimum-stability dev; \
      composer config prefer-stable true; \
      composer config repositories.canvas --json '{"type": "path", "url": "../canvas", "options": {"symlink": false}}'; \
      if [ "${version#11.4.}" != "$version" ]; then composer require twig/twig:3.29.0 --no-update; fi; \
      composer require "drupal/core-dev:$version" "drupal/canvas @dev" --with-all-dependencies --no-install --no-interaction; \
      composer require $packages --dev -W --no-interaction; \
      cd ..; \
    done

# npm + Turborepo: mirror the `.canvas-ui` CI step, plus the browser downloads
# from the `cache dependencies` job. Canvas only tests in headless Chromium, so
# only Playwright's headless shell is installed. Canvas writes its Astro and
# TypeScript caches to the repo's own .cache directory, so point that at the
# cache dir too. Make everything writable by whichever user CI runs as.
RUN ln -s "$CANVAS_CACHE_DIR" canvas/.cache && \
    cd canvas && \
    npm ci && \
    npm run build -w ui && \
    npx playwright install --only-shell chromium && \
    npx cypress install && \
    chmod -R a+rwX "$CANVAS_CACHE_DIR"

# Drupal Canvas image: Chromium-only OS dependencies plus warm Composer, npm,
# Turborepo, Astro, TypeScript, Playwright and Cypress caches for Canvas,
# copied in as one layer. Build with `--target canvas`.
FROM chromium-deps AS canvas

# Cypress's OS dependencies that Playwright's Chromium dependencies don't
# already cover. See https://on.cypress.io/required-dependencies.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    libgtk-3-0t64 \
    libnotify4 \
    libxss1 \
    libxtst6 \
    xauth \
    && rm -rf /var/lib/apt/lists/* /usr/share/doc/* /usr/share/man/*

ENV CANVAS_CACHE_DIR=/opt/canvas-cache
ENV COMPOSER_CACHE_DIR=${CANVAS_CACHE_DIR}/composer \
    COMPOSER_HOME=${CANVAS_CACHE_DIR}/composer-home \
    npm_config_cache=${CANVAS_CACHE_DIR}/npm \
    TURBO_CACHE_DIR=${CANVAS_CACHE_DIR}/turbo \
    PLAYWRIGHT_BROWSERS_PATH=${CANVAS_CACHE_DIR}/ms-playwright \
    CYPRESS_CACHE_FOLDER=${CANVAS_CACHE_DIR}/cypress

COPY --from=canvas-build /opt/canvas-cache /opt/canvas-cache

# Generic image with Playwright's Chromium only. Build with `--target chromium`.
FROM chromium-deps AS chromium

# Use current date to bust cache
# Install current browsers
RUN date > /tmp/cache-bust && npx playwright install --with-deps chromium && \
    rm -rf /root/.npm /var/lib/apt/lists/* /tmp/* /var/tmp/* /usr/share/doc/* /usr/share/man/*

# The generic image with every Playwright browser. As the last stage it's the
# default target, so a plain `docker build .` still produces it.
FROM base AS default

# Install Playwright OS dependencies.
RUN npx playwright install-deps && \
    rm -rf /root/.npm /var/lib/apt/lists/* /tmp/* /var/tmp/* /usr/share/doc/* /usr/share/man/*

# Use current date to bust cache
# Install current browsers
RUN date > /tmp/cache-bust && npx playwright install --with-deps && \
    rm -rf /root/.npm /var/lib/apt/lists/* /tmp/* /var/tmp/* /usr/share/doc/* /usr/share/man/*
