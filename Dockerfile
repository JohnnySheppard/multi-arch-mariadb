FROM debian:stretch-slim

# add our user and group first to make sure their IDs get assigned consistently, regardless of whatever dependencies get added
RUN groupadd -r mysql && useradd -r -g mysql mysql

# https://bugs.debian.org/830696 (apt uses gpgv by default in newer releases, rather than gpg)
RUN set -ex; \
    apt-get update; \
    if ! which gpg; then \
    apt-get install -y --no-install-recommends gnupg; \
    fi; \
    # Ubuntu includes "gnupg" (not "gnupg2", but still 2.x), but not dirmngr, and gnupg 2.x requires dirmngr
    # so, if we're not running gnupg 1.x, explicitly install dirmngr too
    if ! gpg --version | grep -q '^gpg (GnuPG) 1\.'; then \
    apt-get install -y --no-install-recommends dirmngr; \
    fi; \
    rm -rf /var/lib/apt/lists/*

# add gosu for easy step-down from root
ENV GOSU_VERSION 1.10
RUN set -ex; \
    \
    fetchDeps=' \
    ca-certificates \
    wget \
    '; \
    apt-get update; \
    apt-get install -y --no-install-recommends $fetchDeps; \
    rm -rf /var/lib/apt/lists/*; \
    \
    dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')"; \
    wget -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch"; \
    wget -O /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch.asc"; \
    \
    # verify the signature
    export GNUPGHOME="$(mktemp -d)"; \
    gpg --batch --keyserver p80.pool.sks-keyservers.net --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4; \
    gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu; \
    command -v gpgconf > /dev/null && gpgconf --kill all || :; \
    rm -r "$GNUPGHOME" /usr/local/bin/gosu.asc; \
    \
    chmod +x /usr/local/bin/gosu; \
    # verify that the binary works
    gosu nobody true; \
    \
    apt-get purge -y --auto-remove $fetchDeps

RUN mkdir /docker-entrypoint-initdb.d

# install "apt-transport-https" for Percona's repo (switched to https-only)
# install "pwgen" for randomizing passwords
# install "tzdata" for /usr/share/zoneinfo/
RUN apt-get update && apt-get install -y --no-install-recommends \
    #    apt-transport-https ca-certificates \
    pwgen \
    tzdata \
    && rm -rf /var/lib/apt/lists/*


ENV MARIADB_MAJOR 10.1
ENV MARIADB_VERSION 10.1.37-0+deb9u1

# the "/var/lib/mysql" stuff here is because the mysql-server postinst doesn't have an explicit way to disable the mysql_install_db codepath besides having a database already "configured" (ie, stuff in /var/lib/mysql/mysql)
# also, we set debconf keys to make APT a little quieter
RUN set -ex; \
    { \
    echo "mariadb-server-$MARIADB_MAJOR" mysql-server/root_password password 'unused'; \
    echo "mariadb-server-$MARIADB_MAJOR" mysql-server/root_password_again password 'unused'; \
    } | debconf-set-selections; \
    apt-get update; \
    apt-get install -y \
    "mariadb-server=$MARIADB_VERSION" \
    # percona-xtrabackup/mariadb-backup is installed at the same time so that `mysql-common` is only installed once from just mariadb repos
    socat \
    ; \
    rm -rf /var/lib/apt/lists/*; \
    # comment out any "user" entires in the MySQL config ("docker-entrypoint.sh" or "--user" will handle user switching)
    sed -ri 's/^user\s/#&/' /etc/mysql/my.cnf /etc/mysql/conf.d/*; \
    # purge and re-create /var/lib/mysql with appropriate ownership
    rm -rf /var/lib/mysql; \
    mkdir -p /var/lib/mysql /var/run/mysqld; \
    chown -R mysql:mysql /var/lib/mysql /var/run/mysqld; \
    # ensure that /var/run/mysqld (used for socket and lock files) is writable regardless of the UID our mysqld instance ends up having at runtime
    chmod 777 /var/run/mysqld; \
    # comment out a few problematic configuration values
    find /etc/mysql/ -name '*.cnf' -print0 \
    | xargs -0 grep -lZE '^(bind-address|log)' \
    | xargs -rt -0 sed -Ei 's/^(bind-address|log)/#&/'; \
    # don't reverse lookup hostnames, they are usually another container
    echo '[mysqld]\nskip-host-cache\nskip-name-resolve' > /etc/mysql/conf.d/docker.cnf

VOLUME /var/lib/mysql

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh \
    && ln -s usr/local/bin/docker-entrypoint.sh / # backwards compat
ENTRYPOINT ["docker-entrypoint.sh"]

EXPOSE 3306
CMD ["mysqld"]



