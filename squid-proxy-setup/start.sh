#!/usr/bin/env bash

SQUID_IMG="${SQUID_IMG:-"nascarsayan/squid-proxy:latest"}"
SQUID_CONFIG="$(base64 -w 0 "files/squid.conf")"

files=$(ls files)
FILES=""
for file in $files
do
  if [ ! "$file" == "squid.conf" ]; then
    content=$(base64 -w 0 "files/$file")
    FILES="$FILES;$file:$content"
  fi
done
FILES="${FILES:1}"

docker run -d \
  --env SQUID_CONFIG="$SQUID_CONFIG" \
  --env FILES="$FILES" \
  --name squid-proxy \
  --restart on-failure:3 \
  -p 3128:3128 -p 3129:3129 \
  -p 3130:3130 -p 3131:3131 \
  "$SQUID_IMG"
