tag=$1
if [ -z $tag ]
then
  tag="latest"
fi
sudo docker build --no-cache . -t pchahal24/squid-proxy:$tag
sudo docker push pchahal24/squid-proxy:$tag
