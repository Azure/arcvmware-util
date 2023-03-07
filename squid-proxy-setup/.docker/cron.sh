#!/usr/bin/env bash
if [ ! -f "/usr/local/squid/var/logs/access.log" ]; then
  exit 0
fi

file_size=$(stat --printf="%s" /usr/local/squid/var/logs/access.log)
if [ "$file_size" -gt 104857600 ]; then
  /usr/local/squid/sbin/squid -k rotate
  rm /usr/local/squid/var/logs/access.log.*
  rm /usr/local/squid/var/logs/cache.log.*
fi

PORT="$(grep -oP '^http_port \K\d+$' /files/squid.conf)"
PROXY="http://127.0.0.1:${PORT}"
if [ -n "$SQUID_AUTH_CREDS" ]; then
  PROXY="http://${SQUID_AUTH_CREDS}@127.0.0.1:${PORT}/"
fi

curl --proxy "$PROXY" -sf --retry 6 --max-time 5 --retry-delay 10 --retry-max-time 60 "http://google.com" || killall5 -9
