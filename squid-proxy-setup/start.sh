SQUID_CONFIG=$(cat files/squid.conf | base64 -w 0)

files=$(ls files)
FILES=""
for file in $files
do
  if [ ! $file == "squid.conf" ]
  then
    content=$(cat files/$file | base64 -w 0)
    FILES="$FILES;$file:$content"
  fi
done
FILES="${FILES:1}"

docker run -d --env SQUID_CONFIG=$SQUID_CONFIG --env FILES=$FILES --name squid-proxy --restart unless-stopped --net host pchahal24/squid-proxy:2022-12-02
