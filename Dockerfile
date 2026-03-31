#p Testing image used for GitLab CI
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
    curl \
    jq \
    unzip \
    ca-certificates \
    sudo \
    git \
    && apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Configure GD with jpeg, freetype, and avif support.
RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-avif

# Install PHP extensions required by Drupal
RUN docker-php-ext-install -j$(nproc) \
    sodium \
    pdo \
    pdo_mysql \
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
