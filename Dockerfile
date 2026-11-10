# syntax=docker/dockerfile:1
# Testing image used for GitLab CI
FROM php:8.3-apache AS base

# Disbale npm lifecycle scripts.
ENV npm_config_ignore_scripts=true

# Install Node.js 24 (includes npm)
# Clean up Yarn repository to prevent GPG key expiration errors
# Yarn's GPG key (23E7166788B63E1E) has expired, causing apt-get failures if repository is present
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -f /etc/apt/sources.list.d/yarn.list /usr/share/keyrings/yarnkey.gpg

RUN apt-get install -y --no-install-recommends \
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
    rm -rf /var/lib/apt/lists/*

# Configure GD with jpeg, freetype, and avif support.
RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-avif

# Install PHP extensions required by Drupal
RUN docker-php-ext-install -j$(nproc) \
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
    simplexml

RUN apt-get clean && \
    rm -rf /var/lib/apt/lists/* \
    /tmp/* \
    /var/tmp/* \
    /usr/share/doc/* \
    /usr/share/man/*

COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Enable Apache mod_rewrite (if needed)
RUN a2enmod rewrite

# Set high limit for CLI (unlimited)
RUN echo "memory_limit = -1" > /usr/local/etc/php/conf.d/cli-memory.ini
# Set reasonable limit for Apache
RUN echo "memory_limit = 512M" > /usr/local/etc/php/conf.d/apache-memory.ini
RUN echo "post_max_size = 64M" > /usr/local/etc/php/conf.d/post-max-size.ini

# Install Playwright OS dependencies.
RUN npx playwright install-deps

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

# Use current date to bust cache
# Install current browsers
RUN date > /tmp/cache-bust && npx playwright install --with-deps

WORKDIR /var/www/html

# Drupal Canvas image: the base image plus warm npm, Composer, Turborepo,
# Playwright and Cypress caches for https://www.drupal.org/project/canvas.
# Build with `--target canvas`.
FROM base AS canvas

ARG CANVAS_REPO=https://git.drupalcode.org/project/canvas.git
ARG CANVAS_REF=1.x
# Defaults to DRUPAL_CORE from Canvas's .gitlab-ci.yml; set to override.
ARG DRUPAL_CORE=

# Canvas's CI points these at $CI_PROJECT_DIR/.cache/*; leave them unset there
# (or copy from here) to use the caches baked into this image.
ENV CANVAS_CACHE_DIR=/opt/canvas-cache
ENV COMPOSER_CACHE_DIR=${CANVAS_CACHE_DIR}/composer \
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

# npm + Turborepo: mirror the `.canvas-ui` CI step, plus the browser downloads
# from the `cache dependencies` job.
RUN cd /tmp/canvas-build/canvas && \
    npm ci && \
    npm run build -w ui && \
    npx playwright install && \
    npx cypress install

# Composer: mirror `.drupal-files-with-dev-dependencies` in Canvas's CI.
RUN cd /tmp/canvas-build && \
    DRUPAL_CORE=${DRUPAL_CORE:-$(sed -n 's/^  DRUPAL_CORE: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' canvas/.gitlab-ci.yml)} && \
    test -n "${DRUPAL_CORE}" && echo "Using Drupal core ${DRUPAL_CORE}" && \
    composer create-project drupal/recommended-project:${DRUPAL_CORE} _drupal --no-install --no-interaction && \
    cd _drupal && \
    composer config minimum-stability dev && \
    composer config prefer-stable true && \
    composer config repositories.canvas --json '{"type": "path", "url": "../canvas", "options": {"symlink": false}}' && \
    if [ "${DRUPAL_CORE#11.4.}" != "${DRUPAL_CORE}" ]; then composer require twig/twig:3.29.0 --no-update; fi && \
    composer require "drupal/core-dev:${DRUPAL_CORE}" "drupal/canvas @dev" --with-all-dependencies --no-install --no-interaction && \
    PACKAGES=$(jq -r '.["require-dev"] // {} | to_entries[] | "\(.key):\(.value)"' ../canvas/composer.json | tr '\n' ' ') && \
    composer require ${PACKAGES} --dev -W --no-interaction

# Keep only the caches; make them writable by whichever user CI runs as.
RUN rm -rf /tmp/canvas-build && \
    chmod -R a+rwX ${CANVAS_CACHE_DIR}

WORKDIR /var/www/html

# The last stage is the default target, so a plain `docker build .` still
# produces the generic image.
FROM base AS default
