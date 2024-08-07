#!/usr/bin/env bash
function error() {
  if [ -n "$1" ]
  then
    echo "$1"
  fi
  exit 1
}

if [ -z "$SQUID_CONFIG" ]; then
  error "SQUID_CONFIG environment variable is required."
fi

if [ -d "/files" ]; then
  rm -r /files
fi

mkdir /files
cd /files || error "Error while changing directory to /files"

# shellcheck disable=SC2153
files=$(echo "$FILES" | tr ";" "\n")
for file in $files
do
  name="$(cut -d':' -f1 <<<"$file")"
  content="$(cut -d':' -f2 <<<"$file")"
  if [ -f "$name" ]; then
    error "File $name already exists, please choose different name."
  fi
  base64 -d <<< "$content" > "$name"
done

base64 -d <<< "$SQUID_CONFIG" > squid.conf

if [ -f "setup.sh" ]; then
  bash ./setup.sh
  if [ "$?" == "1" ]; then
    error "Error while running setup script"
  fi
fi

/usr/local/squid/sbin/squid start -f squid.conf

echo "* * * * * /cron.sh" | crontab -
service cron restart

tail -F /usr/local/squid/var/logs/access.log
