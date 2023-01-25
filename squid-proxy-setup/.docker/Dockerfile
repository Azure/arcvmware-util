FROM ubuntu
ARG DEBIAN_FRONTEND=noninteractive
RUN apt update &&\
  apt install -y --no-install-recommends apt-utils &&\
  dpkg-reconfigure apt-utils &&\
  apt install -y libssl-dev pkg-config build-essential autoconf wget jq curl vim cron &&\
  apt upgrade -y

RUN groupadd -g 456 squid &&\
  useradd -g squid squid

RUN curl -L http://www.squid-cache.org/Versions/v4/squid-4.14.tar.gz | tar -xz

WORKDIR /squid-4.14
RUN ./configure --with-default-user=proxy --with-openssl --enable-ssl-crtd --disable-arch-native
RUN make
RUN make install

RUN chmod 777 /usr/local/squid/var/logs
RUN /usr/local/squid/libexec/security_file_certgen -c -s /usr/local/squid/var/cache/squid/ssl_db -M 4MB
RUN chown proxy:proxy /usr/local/squid/var/cache/squid/ssl_db -R

WORKDIR /
RUN rm -r /squid-4.14

COPY startup.sh .
RUN chmod +x startup.sh

COPY rotate_access_logs_and_cleanup.sh .
RUN chmod +x rotate_access_logs_and_cleanup.sh

CMD ["bash", "startup.sh"]