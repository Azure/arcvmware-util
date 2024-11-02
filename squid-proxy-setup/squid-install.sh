#!/bin/bash
export SQUID_VERSION=6.10


files_dir=$(find ~ -type d -path "*arcvmware-util/squid-proxy-setup/files" 2>/dev/null | head -n 1)
if [ -z "$files_dir" ]; then
  echo "Could not find any directory matching '*arcvmware-util/squid-proxy-setup/files' in your home directory. Please clone the repository somewhere inside home dir and try again."
  exit 1
fi
export files_dir

# if squid cert file is empty, ask user to fix the files before installing
if [ ! -s "$files_dir/proxy-ca.crt" ] || [ ! -s "$files_dir/proxy-ca.key" ]; then
  echo "Proxy cert files are empty. Please update the files as per the instructions and then run the script again."
  exit 1
fi

# Dependencies from
# https://github.com/kinkie/dockerfiles/blob/8f1468c3016fba0393f13c3a19662a5fc05ca9ab/ubuntu-jammy/Dockerfile
# as per https://wiki.squid-cache.org/SquidFaq/CompilingSquid#what-else-do-i-need-to-compile-squid
sudo apt update && \
  DEBIAN_FRONTEND=noninteractive sudo apt install --no-install-recommends -y \
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

sudo groupadd -g 456 squid && \
  sudo useradd -g squid squid

# NOTE: We can also add the flags mentioned below for changing the directory paths of squid files.
# Currently, systemd unit file is causing issues, so we are directly running squid binary.
# This is the unit file: https://github.com/squid-cache/squid/blob/master/tools/systemd/squid.service
# TODO: Check how to make systemd unit file work, and if these flags are related to that.
# https://wiki.squid-cache.org/SquidFaq/CompilingSquid#debian-ubuntu
# 

mkdir -p /tmp/build && \
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
  sudo make install && \
  sudo rm -rf /tmp/build

sudo chmod 777 /usr/local/squid/var/logs && \
  sudo /usr/local/squid/libexec/security_file_certgen -c -s \
  /usr/local/squid/var/cache/squid/ssl_db -M 4MB && \
  sudo chown -R squid:squid /usr/local/squid/

certs_dir="$files_dir/../certs"
sudo cp "$certs_dir"/microsoft.crt /usr/local/share/ca-certificates/microsoft.crt
sudo update-ca-certificates

sudo ln -s "$files_dir/squid.conf" /usr/local/squid/etc/squid.conf

sed 's@/files@'"$files_dir"'@g' "$files_dir/squid.conf" | sudo tee /usr/local/squid/etc/squid.conf > /dev/null
sudo ln -s "$files_dir/proxy_ca.crt" /usr/local/squid/etc/
sudo ln -s "$files_dir/proxy_ca.key" /usr/local/squid/etc/

sudo ln -s /usr/local/squid/sbin/squid /usr/sbin/

echo "Creating a wrapper script 'sq' to manage squid service. Run 'sq' for more options."

cat <<'EOF' | sudo tee /usr/local/bin/sq > /dev/null
#!/bin/bash

if [ -z "$1" ]; then
  echo "Usage: sq [start|stop|status|access|cache|logs]"
  exit 1
fi

case "$1" in
  "start")
    sudo squid -N -d 10 -f /usr/local/squid/etc/squid.conf
    ;;
  "stop")
    sudo squid -k shutdown
    sudo pkill squid
    ;;
  "status")
    sudo squid -k check
    ;;
  "access")
    sudo tail -f /usr/local/squid/var/logs/access.log
    ;;
  "cache")
    sudo tail -f /usr/local/squid/var/logs/cache.log
    ;;
  "logs")
    sudo journalctl -f -u squid
  *)
    echo "Invalid command: '$1'. Usage: sq [start|stop|status|access|cache|logs]"
    exit 1
    ;;
esac
EOF

echo "Adding squid service to systemd to start on boot. It will run /usr/local/bin/sq start"

cat <<'EOF' | sudo tee /etc/systemd/system/squid.service > /dev/null
[Unit]
Description=Squid Proxy Server
After=network.target network-online.target nss-lookup.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sq start
ExecStop=/usr/local/bin/sq stop
ExecReload=/bin/kill -HUP $MAINPID
User=root
Group=root
# Remove StandardError and StandardOutput directives to let journald handle logging
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable squid

# rotate logs every sunday
echo "0 0 * * 0 /usr/local/squid/sbin/squid -k rotate" | sudo crontab -

sudo chmod +x /usr/local/bin/sq
# start squid on boot

cat << EOF
Squid setup complete.
Verify by running 'sudo squid -N -d 10'.
Debug level can be changed by changing the value of -d flag.
-N will run squid in foreground.
Start squid using 'systemctl start squid'.
Run 'sq' for more options.
EOF
