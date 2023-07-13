FROM ubuntu:22.04
ARG SQUID_VERSION=5.7

# Dependencies from
# https://github.com/kinkie/dockerfiles/blob/8f1468c3016fba0393f13c3a19662a5fc05ca9ab/ubuntu-jammy/Dockerfile
# as per https://wiki.squid-cache.org/SquidFaq/CompilingSquid#what-else-do-i-need-to-compile-squid
RUN apt update && \
  DEBIAN_FRONTEND=noninteractive apt install --no-install-recommends -y \
    autoconf \
    autoconf-archive \
    automake \
    build-essential \
    bzip2 \
    ca-certificates \
    ccache \
    clang \
    cron \
    curl \
    ed \
    g++ \
    git \
    gnutls-bin \
    jq \
    libcap-dev \
    libcppunit-dev \
    libexpat-dev \
    libgnutls28-dev \
    libltdl-dev \
    libssl-dev \
    libtdb-dev \
    libtool \
    libtool-bin \
    libxml2-dev \
    make \
    nettle-dev \
    pkg-config \
    po4a \
    translate-toolkit \
    vim \
    wget \
    xz-utils

RUN groupadd -g 456 squid && \
  useradd -g squid squid

RUN mkdir -p /tmp/build && \
  cd /tmp/build && \
  curl -L \
  "http://www.squid-cache.org/Versions/v${SQUID_VERSION%%.*}/squid-${SQUID_VERSION}.tar.gz" | \
    tar -xz --strip-components 1 && \
  ./configure \
    --with-default-user=squid \
    --with-openssl \
    --enable-ssl-crtd \
    --enable-delay-pools \
    --disable-arch-native && \
  make && \
  make install && \
  rm -rf /tmp/build

RUN chmod 777 /usr/local/squid/var/logs && \
  /usr/local/squid/libexec/security_file_certgen -c -s \
    /usr/local/squid/var/cache/squid/ssl_db -M 4MB && \
  chown squid:squid /usr/local/squid/var/cache/squid/ssl_db -R

COPY certs/microsoft.crt /usr/local/share/ca-certificates/microsoft.crt
RUN update-ca-certificates

WORKDIR /

COPY startup.sh cron.sh ./
RUN chmod +x startup.sh cron.sh

CMD ["bash", "startup.sh"]
