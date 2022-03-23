FROM php:8.0.17-apache-bullseye
FROM debian:11.2

# Prepare Apt-Installer
RUN echo "#!/bin/bash" > apt-install
RUN echo 'apt-get update; apt-get install -y --no-install-recommends $@; rm -rf /var/lib/apt/lists/*;' >> apt-install
RUN chmod 777 apt-install
RUN mv apt-install /usr/local/bin

# Prevent PHP-Packages from being Installed using APT
RUN \
    { \
        echo 'Package: php*'; \
        echo 'Pin: release *'; \
        echo 'Pin-Priority: -1'; \
    } > /etc/apt/preferences.d/no-debian-php

# Configure the Locale
RUN apt-install locales

RUN \
    echo "LANG=en_US.UTF-8\n" > /etc/default/locale && \
    echo "en_US.UTF-8 UTF-8\n" > /etc/locale.gen && \
    locale-gen

# Install PHP-Dependencies
ENV PHPIZE_DEPS \
        autoconf \
        dpkg-dev \
        file \
        g++ \
        gcc \
        libc-dev \
        make \
        pkg-config \
        re2c

RUN \
    apt-install \
        ${PHPIZE_DEPS} \
        ca-certificates \
        curl \
        xz-utils

## Prepare Filesystem
ENV PHP_INI_DIR /usr/local/etc/php
RUN \
    mkdir -p "${PHP_INI_DIR}/conf.d"; \
    [ ! -d /var/www/html ]; \
    mkdir -p /var/www/html; \
    chown www-data:www-data /var/www/html; \
    chmod 777 /var/www/html

# Install Apache
ENV APACHE_CONFDIR /etc/apache2
ENV APACHE_ENVVARS ${APACHE_CONFDIR}/envvars

RUN \
    apt-install apache2 && \
    sed -ri 's/^export ([^=]+)=(.*)$/: ${\1:=\2}\nexport \1/' "$APACHE_ENVVARS"; \
    \
    . "${APACHE_ENVVARS}"; \
    for dir in \
        "$APACHE_LOCK_DIR" \
        "$APACHE_RUN_DIR" \
        "$APACHE_LOG_DIR" \
    ; do \
        rm -rvf "$dir"; \
        mkdir -p "$dir"; \
        chown "$APACHE_RUN_USER:$APACHE_RUN_GROUP" "$dir"; \
        chmod 777 "$dir"; \
    done; \
    rm -rvf /var/www/html/*; \
    ln -sfT /dev/stderr "$APACHE_LOG_DIR/error.log"; \
    ln -sfT /dev/stdout "$APACHE_LOG_DIR/access.log"; \
    ln -sfT /dev/stdout "$APACHE_LOG_DIR/other_vhosts_access.log"; \
    chown -R --no-dereference "$APACHE_RUN_USER:$APACHE_RUN_GROUP" "$APACHE_LOG_DIR"

RUN a2dismod mpm_event && a2enmod mpm_prefork

## Remove `/icons/` alias entry as SilverStripe uses this path
RUN sed -i 's/\(Alias \/icons\/.*\)$/# \1/' /etc/apache2/mods-enabled/alias.conf

## Configuring Apache for handling PHP-Files
RUN { \
        echo '<FilesMatch \.php$>'; \
        echo '    SetHandler application/x-httpd-php'; \
        echo '</FilesMatch>'; \
        echo; \
        echo 'DirectoryIndex disabled'; \
        echo 'DirectoryIndex index.php index.html'; \
        echo; \
        echo '<Directory /var/www/>'; \
        echo '    Options -Indexes'; \
        echo '    AllowOverride All'; \
        echo '</Directory>'; \
    } | tee "$APACHE_CONFDIR/conf-available/docker-php.conf" \
    && a2enconf docker-php

# Build PHP
ENV PHP_EXTRA_BUILD_DEPS apache2-dev
ENV PHP_EXTRA_CONFIGURE_ARGS --with-apxs2 --disable-cgi

ENV PHP_CFLAGS="-fstack-protector-strong -fpic -fpie -O2 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64"
ENV PHP_CPPFLAGS="$PHP_CFLAGS"
ENV PHP_LDFLAGS="-Wl,-O1 -Wl,--hash-style=both -pie"

ENV GPG_KEYS 528995BFEDFBA7191D46839EF9BA0ADA31CBD89E \
             39B641343D8C104B2B146DC3F9C39DC0B9698544 \
             F1F692238FBC1666E5A5CCD4199F9DFEF6FFBAFD

ENV PHP_VERSION 8.0.17
ENV PHP_URL="https://www.php.net/distributions/php-${PHP_VERSION}.tar.xz" PHP_ASC_URL="https://www.php.net/distributions/php-${PHP_VERSION}.tar.xz.asc"
ENV PHP_SHA256="4e7d94bb3d144412cb8b2adeb599fb1c6c1d7b357b0d0d0478dc5ef53532ebc5"

## Download and Verify PHP Source
RUN \
    savedAptMark="$(apt-mark showmanual)"; \
    apt-install gnupg dirmngr; \
    mkdir -p /usr/src; \
    cd /usr/src; \
    \
    curl -fsSL -o php.tar.xz "$PHP_URL"; \
    \
    if [ -n "${PHP_SHA256}" ]; then \
        echo "${PHP_SHA256} *php.tar.xz" | sha256sum -c -; \
    fi; \
    \
    if [ -n "${PHP_ASC_URL}" ]; then \
        curl -fsSL -o php.tar.xz.asc "${PHP_ASC_URL}"; \
        export GNUPGHOME="$(mktemp -d)"; \
        for key in $GPG_KEYS; do \
            gpg --batch --keyserver ha.pool.sks-keyservers.net --recv-keys "$key"; \
        done; \
        gpg --batch --verify php.tar.xz.asc php.tar.xz; \
        gpgconf --kill all; \
        rm -rf "$GNUPGHOME"; \
    fi; \
    \
    apt-mark auto '.*' > /dev/null; \
    apt-mark manual $savedAptMark > /dev/null; \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false

COPY --from=0 /usr/local/bin/docker-php-source /usr/local/bin/

## Perform Build
RUN \
    savedAptMark="$(apt-mark showmanual)"; \
    apt-install \
        libargon2-dev \
        libcurl4-openssl-dev \
        libedit-dev \
        libonig-dev \
        libsodium-dev \
        libsqlite3-dev \
        libssl-dev \
        libxml2-dev \
        zlib1g-dev \
        ${PHP_EXTRA_BUILD_DEPS:-} \
    ; \
    export \
        CFLAGS="${PHP_CFLAGS}" \
        CPPFLAGS="${PHP_CPPFLAGS}" \
        LDFLAGS="${PHP_LDFLAGS}" \
    ; \
    docker-php-source extract; \
    cd /usr/src/php; \
    gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"; \
    debMultiarch="$(dpkg-architecture --query DEB_BUILD_MULTIARCH)"; \
    if [ ! -d /usr/include/curl ]; then \
        ln -sT "/usr/include/$debMultiarch/curl" /usr/local/include/curl; \
    fi; \
    ./configure \
        --build="$gnuArch" \
        --with-config-file-path="${PHP_INI_DIR}" \
        --with-config-file-scan-dir="${PHP_INI_DIR}/conf.d" \
        --enable-option-checking=fatal \
        --with-mhash \
        --enable-ftp \
        --enable-mbstring \
        --enable-mysqlnd \
        --with-password-argon2 \
        --with-sodium=shared \
        --with-pdo-sqlite=/usr \
        --with-sqlite3=/usr \
        --with-curl \
        --with-libedit \
        --with-openssl \
        --with-zlib \
        --with-pear \
        $(test "$gnuArch" = 's390x-linux-gnu' && echo '--without-pcre-jit') \
        --with-libdir="lib/$debMultiarch" \
        ${PHP_EXTRA_CONFIGURE_ARGS:-} \
    ; \
    make -j "$(nproc)"; \
    find -type f -name '*.a' -delete; \
    make install; \
    find /usr/local/bin /usr/local/sbin -type f -executable -exec strip --strip-all '{}' + || true; \
    make clean; \
    \
    cp -v php.ini-* "${PHP_INI_DIR}/"; \
    \
    cd /; \
    docker-php-source delete; \
    \
    apt-mark auto '.*' > /dev/null; \
    [ -z "$savedAptMark" ] || apt-mark manual $savedAptMark; \
    find /usr/local -type f -executable -exec ldd '{}' ';' \
        | awk '/=>/ { print $(NF-1) }' \
        | sort -u \
        | xargs -r dpkg-query --search \
        | cut -d: -f1 \
        | sort -u \
        | xargs -r apt-mark manual \
    ; \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    \
    pecl update-channels; \
    rm -rf /tmp/pear ~/.pearrc; \
    php --version

COPY --from=0 /usr/local/bin/docker-php-ext-* /usr/local/bin/docker-php-entrypoint /usr/local/bin/

RUN docker-php-ext-enable sodium

ENTRYPOINT [ "docker-php-entrypoint" ]
STOPSIGNAL SIGWINCH

COPY --from=0 /usr/local/bin/apache2-foreground /usr/local/bin/

# Install Composer
RUN apt-install \
        git \
        subversion \
        openssh-client \
        mercurial \
        tini \
        bash \
        patch \
        make \
        zip \
        unzip \
        coreutils \
        zlib1g-dev \
        libzip-dev \
        pax-utils && \
    docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) zip opcache && \
    runDeps="$( \
    scanelf --needed --nobanner --format '%n#p' --recursive /usr/local/lib/php/extensions \
      | tr ',' '\n' \
      | sort -u \
      | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )" && \
    apt-install $runDeps && \
    apt-get purge -y --auto-remove pax-utils && \
    printf \
        "# composer php cli ini settings\n\
        date.timezone=UTC\n\
        memory_limit=-1\n\
        opcache.enable_cli=1\n\
        " > $PHP_INI_DIR/php-cli.ini

ENV COMPOSER_ALLOW_SUPERUSER 1
ENV COMPOSER_HOME /tmp
ENV COMPOSER_VERSION 2.2.9

RUN curl --silent --fail --location --retry 3 -o /tmp/installer.php --url https://raw.githubusercontent.com/composer/getcomposer.org/f24b8f860b95b52167f91bbd3e3a7bcafe043038/web/installer && \
    echo 3137ad86bd990524ba1dedc2038309dfa6b63790d3ca52c28afea65dcc2eaead16fb33e9a72fd2a7a8240afaf26e065939a2d472f3b0eeaa575d1e8648f9bf19 /tmp/installer.php | sha512sum --strict --check && \
    php /tmp/installer.php --no-ansi --install-dir=/usr/bin --filename=composer --version=${COMPOSER_VERSION} && \
    composer --ansi --version --no-interaction && \
    rm -f /tmp/installer.php && \
    find /tmp -type d -exec chmod -v 1777 {} +

# Install NodeJS
RUN \
    groupadd --gid 1000 node && \
    useradd --uid 1000 --gid node --shell /bin/bash --create-home node

ENV NODE_VERSION 17.7.2

RUN \
    ARCH= && dpkgArch="$(dpkg --print-architecture)" && \
    case "${dpkgArch##*-}" in \
        amd64) ARCH='x64';; \
        ppc64el) ARCH='ppc64le';; \
        s390x) ARCH='s390x';; \
        arm64) ARCH='arm64';; \
        armhf) ARCH='armv7l';; \
        i386) ARCH='x86';; \
        *) echo "unsupported architecture"; exit 1 ;; \
    esac && \
    apt-install ca-certificates curl wget gnupg dirmngr xz-utils && \
    # gpg keys listed at https://github.com/nodejs/node#release-keys
    set -ex && \
    for key in \
      4ED778F539E3634C779C87C6D7062848A1AB005C \
      141F07595B7B3FFE74309A937405533BE57C7D57 \
      94AE36675C464D64BAFA68DD7434390BDBE9B9C5 \
      74F12602B6F1C4E913FAA37AD3A89613643B6201 \
      71DCFD284A79C3B38668286BC97EC7A07EDE3FC1 \
      8FCCA13FEF1D0C2E91008E09770F7A9A5AE15600 \
      C4F0DFFF4E8C1A8236409D08E73BC641CC11F4C8 \
      C82FA3AE1CBEDC6BE46B9360C43CEC45C17AB93C \
      DD8F2338BAE7501E3DD5AC78C273792F7D83545D \
      A48C2BEE680E841632CD4E44F07496B3EB3C1762 \
      108F52B48DB57BB0CC439B2997B01419BD92F80A \
      B9E2F5981AA6E0CD28160D9FF13993A75599653C \
    ; do \
      gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys "$key" || \
      gpg --batch --keyserver keyserver.ubuntu.com --recv-keys "$key" ; \
    done && \
    curl -fsSLO --compressed "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${ARCH}.tar.xz" && \
    curl -fsSLO --compressed "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt.asc" && \
    gpg --batch --decrypt --output SHASUMS256.txt SHASUMS256.txt.asc && \
    grep " node-v${NODE_VERSION}-linux-${ARCH}.tar.xz\$" SHASUMS256.txt | sha256sum -c - && \
    tar -xJf "node-v${NODE_VERSION}-linux-${ARCH}.tar.xz" -C /usr/local --strip-components=1 --no-same-owner && \
    rm "node-v${NODE_VERSION}-linux-${ARCH}.tar.xz" SHASUMS256.txt.asc SHASUMS256.txt && \
    ln -s /usr/local/bin/node /usr/local/bin/nodejs

# Install Yarn
ENV YARN_VERSION 1.22.18
RUN npm i -g yarn@${YARN_VERSION}

# Install SilverStripe Dependencies
RUN apt-install \
        libfreetype6-dev \
        libicu-dev \
        libmagickwand-dev \
        libjpeg-dev \
        libpng-dev \
        libtidy-dev \
        mariadb-client \
        unzip \
        zip

RUN a2enmod rewrite

RUN docker-php-ext-configure intl
RUN docker-php-ext-configure gd \
    --with-freetype=/usr/include \
    --with-jpeg=/usr/include
RUN docker-php-ext-install \
        gd \
        intl \
        pdo \
        pdo_mysql \
        tidy
RUN pecl install \
        xdebug
RUN mkdir -p /usr/src/php/ext/imagick; \
    curl -fsSL https://github.com/Imagick/imagick/archive/tags/3.7.0.tar.gz | tar xvz -C "/usr/src/php/ext/imagick" --strip 1; \
    docker-php-ext-install imagick;
RUN docker-php-ext-enable \
        xdebug \
        imagick

RUN \
    echo "date.timezone = Pacific/Auckland" > ${PHP_INI_DIR}/conf.d/timezone.ini && \
    { \
        echo "xdebug.mode=debug"; \
        echo "xdebug.start_with_request=yes"; \
        echo "xdebug.client_host='host.docker.internal'"; \
    } > ${PHP_INI_DIR}/conf.d/xdebug.ini

# Clean up the Installation
RUN rm /usr/local/bin/apt-install

WORKDIR /var/www/html

EXPOSE 80
CMD ["apache2-foreground"]
