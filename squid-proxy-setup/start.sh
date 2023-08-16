#!/usr/bin/env bash

if [ -z "$SQUID_AUTH_CREDS" ]; then
  cat <<EOF
SQUID_AUTH_CREDS environment variable is required.
It is required for health check.
It should be in the following format: "username:password".
If the proxy is not protected by authentication, you can set it to "none".
EOF
  exit 1
fi

if [ "$SQUID_AUTH_CREDS" == "none" ]; then
  SQUID_AUTH_CREDS=""
fi

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
  --env SQUID_AUTH_CREDS="$SQUID_AUTH_CREDS" \
  --name squid-proxy \
  --restart on-failure:3 \
  -p 3128:3128 -p 3129:3129 \
  "$SQUID_IMG"
