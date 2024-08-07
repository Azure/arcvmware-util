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
