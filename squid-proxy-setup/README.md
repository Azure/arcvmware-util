# How to create an isolated network with internet access only through the proxy network.

## Existing network

A network segment that has internet access.<br/>
We'll be calling it `internet-segment` hereafter, with subnet `172.16.0.0/22`.

## Network topology we need to create for an isolated proxy network

We need to create a new segment where internet can be accessed only behind a proxy server.<br/>
We'll be calling it `proxy-segment` hereafter, with subnet `192.168.0.0/24`.<br/>
We need not assign any IP subnet from the portal where we are going to create the segment,
since we will have our own DHCP server.

We should assign a static IP to the DHCP server and the Proxy Server. We can run both the service in the same server too.

The network topology should look like this.

![Network Topology](./assets/topology.svg)

## 1. Set up the isolated network

1.  Create an Ubuntu VM that has 2 NICs.
    - `eth0` is connected to `proxy-segment`.
    - `eth1` is connected to `internet-segment`.

     The IP of `eth1` can either be statically assigned or can be obtained via a DHCP server running on `internet-segment`.

2.  Assign a static IP `192.168.0.1` to `eth0`. Various methods:
    1. [Using Netplan - new method][1]
    2. [Using network script - old method][2]
    3. Using GUI:
        ![Static IP](./assets/static-ip.jpg)

    Assuming your public interface is `ens160` and private interface is `ens192`, you can set static IP on private interface, and DHCP on public interface using netplan as follows:

    ```bash
    sudo apt install -y netplan.io
    sudo cat <<'EOF' > /etc/netplan/config.yaml
    network:
      version: 2
      ethernets:
        ens160:
          dhcp4: true
          dhcp6: true
        ens192:
          dhcp4: false
          dhcp6: false
          addresses:
            - 192.168.0.1/16
          nameservers:
            addresses: [10.0.0.192, 8.8.8.8]
    EOF
    sudo netplan apply
    ```

> [!NOTE]
> Here we are using `10.0.0.192` and `8.8.8.8` as our upstream DNS servers.
> You can use any other DNS server as per your requirement.

> [!IMPORTANT]
> From previous experience, DNSServer created by dnsmasq isn't that reliable (might start hanging up after a few days), and it's better to offload the DNS resolution to an external DNS server.
> Hence Case 1 is recommended for **3.2** below.

3.  Run DHCP and DNS Server on the VM. [Ref1][3], [Ref2][4]
    
    If you don't want to set static network configuration for all VMs connected to `proxy-segment`, you will need a DHCP Server. We can install the DHCP server on the same machine where proxy server will be installed. We could have a DNS server in the network too in order to resolve local addresses.<br/>
    [`dnsmasq`][dnsmasq_arch] can serve for both the purposes.

    1.  Install dnsmasq
        
        - Disable systemd-resolved which might conflict with dnsmasq.
        - Remove the existing resolv.conf and create a new one with a working DNS server. This is required for several reasons:
          - Sometimes, this file is a symlink to `/run/systemd/resolve/stub-resolv.conf` which might not be present.
          - Since we've removed systemd-resolved, we need to have a working DNS server. This file is our only helper in name resolution. No other package / service should override the setting in this file.

        ```bash
        sudo systemctl disable systemd-resolved
        sudo systemctl stop systemd-resolved
        sudo rm -f /etc/resolv.conf
        echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf
        sudo apt install -y dnsmasq
        ```
      
    2.  Edit file `/etc/dnsmasq.conf`.

        #### Case 1: Just for DHCP (preferred)
        ```ini
        listen-address=192.168.0.1
        dhcp-range=192.168.0.100,192.168.0.240,12h
        dhcp-option=option:router,192.168.0.1
        dhcp-option=option:dns-server,8.8.8.8
        dhcp-leasefile=/var/lib/misc/dnsmasq.leases
        dhcp-authoritative
        ```

        #### Case 2: For DNS and DHCP both
        ```ini
        listen-address=192.168.0.1
        server=8.8.8.8
        dhcp-range=192.168.0.100,192.168.0.240,12h
        dhcp-option=option:router,192.168.0.1
        dhcp-option=option:dns-server,192.168.0.1,8.8.8.8
        dhcp-leasefile=/var/lib/misc/dnsmasq.leases
        dhcp-authoritative
        ```

        In the 2nd case case, you can also update the entry in `/etc/resolv.conf` to `nameserver 127.0.0.1`. This will make the firewall machine use its own server for DNS resolution.
    
    3.  Restart the dnsmsq service.
        ```bash
        sudo systemctl restart dnsmasq
        ```

## 2. Run squid proxy

1. Clone the repository

```bash
git clone https://github.com/Azure/arcvmware-util.git
cd arcvmware-util/squid-proxy-setup
```

2. Create / Update the files required by squid

    1.  Create CA certificates (Required only for SSL-Proxy)

        We create an SSL certificate and add it to the squid container
        ```bash
        CN="proxy-ca"
        openssl genrsa -out ./files/proxy-ca.key 4096
        openssl req -x509 -new -nodes -key ./files/proxy-ca.key -sha256 -subj "/C=US/ST=CA/CN=$CN" -days 1024 -out ./files/proxy-ca.crt
        ```
        `proxy-ca.crt` is the SSL certificate that will be required to be trusted by the clients who want to use SSL proxy.
    
    2.  Create user credentials (Required only for basic auth)

        For configuring basic auth, i.e., [NCSA auth][6]:<br/>
        Intall htpasswd if not already installed.
        ```bash
        sudo apt install apache2-utils
        ```

        Create the proxy auth credentials file
        ```bash
        # $username, $password will have to be supplied to authenticate to the proxy server
        htpasswd -c ./files/usercreds $username
        # Enter the password when prompted
        ```

    3.  Modify `files/squid.conf` as per your requirement.<br/>
        Any files that you want to copy to the squid container can be put into `files/`.
        The whole directory will be shared as a volume mount to the squid container.

        **For transparent proxy, uncomment the lines in the squid.conf file.**

        ```bash
        perl -pi -e 's/#http_port 3130/http_port 3130/g' files/squid.conf
        perl -pi -e 's/#https_port 3131/https_port 3131/g' files/squid.conf
        ```

        >   Any file want to pass on to container and use in squid config. Just place that file in `files` directory. Those files can be accessed using `/files/<fileName>` inside the container.

        >   **Custom command execution**<br/>
        >   Some custom command can be executed through `setup.sh` script. `setup.sh` script will be executed just before starting the squid proxy server.

3. Install and run squid (**Method 1: using standalone install (preferred)**)

    For standalone install (non-container) in Ubuntu, we can use the [`squid-install.sh`](./squid-install.sh) script.
    **Containerized squid can have performance issues, can hang up after a few days or months.** Hence, it's better to use it as a systemd daemon process.

    ```bash
    ./squid-install.sh
    ```

4. Run squid (**Method 2: using docker**)

    1. Install docker [Ref][5]

    ```bash
    curl -fsSL https://get.docker.com | sh
    # Next add your user to run docker (rootles mode)
    # don't do dockerd-rootless-setuptool.sh install; it limits the number of uid / gids available for user. Causes issues for some docker images.
    sudo newgrp docker
    sudo usermod -aG docker <your-username>
    ```

    2.  Start proxy: [`./start.sh`](./start.sh)<br/>
        View access logs: [`./tail_access_logs.sh`](./tail_access_logs.sh)<br/>
        Stop proxy: [`./stop.sh`](./stop.sh)<br/>

## Transparent Proxy

Configure below rules for transparent proxy

The machine where we configure transparent proxy will have to be used
as the default gateway for the clients using transparent proxy.
We have to make this VM act as a router by enabling NAT.

> [!NOTE]
> By default transparent proxy is disabled in the squid conf file included in this repo. You can enable it [by uncommenting the lines](./files/squid.conf#L40).

### Enable ip forwarding

open file "/etc/sysctl.conf" and uncomment below
```ini
net.ipv4.ip_forward = 1
```
Reload sysctl
```bash
sudo sysctl -p /etc/sysctl.conf
```

### Disable ipv6 (Optional)

Sometimes, ipv6 might cause conflicts. You can disable it if not required.

To disable ipv6, add the following line to `/etc/sysctl.conf`:<br/>
```ini
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
```

Reload sysctl
```bash
sudo sysctl -p /etc/sysctl.conf
```

### Set iptables NAT rules

Check out this [tutorial][nat_iptables] to get an idea of NAT and iptables.
This is another [exhaustive tutorial][exhaustive_iptables_tutorial] on iptables.

> [!IMPORTANT]
> It is important to note that we should redirect HTTP traffic to the non-SSL port (3130 in our config)
> If we redirect the HTTP traffic to the SSL port (3129), we get the error: empty reply from server.

1. Run the [iptables setup script](./iptables-setup.sh) to set the NAT rules.

    ```bash
    bash iptables-setup.sh
    ```

    About the iptables commands in the script:
    1. The NAT table rule changes the source IP address of **all the packets** going out of the machine through the `internet-segment` interface to the IP address of the `internet-segment` interface. `MASQUERADE` is used to dynamically change the source IP address of the packets, since the IP address of the `internet-segment` interface might change. It's similar to `SNAT` but with `MASQUERADE` the source IP address is dynamically changed.
    2. The PREROUTING chain rules redirect all the incoming traffic arriving through proxy-segment:
        - port 80 to port 3130 (the port where the non-SSL proxy is running)
        - port 443 to port 3131 (the port where the SSL proxy is running).
    4. The Port 53 rules are for forwarding DNS traffic to the upstream DNS server. This is required for the clients to resolve the domain names if the DNS server is not running on the proxy server.
    5. The ICMP rules are for forwarding ICMP traffic (ping).

2. Persist the iptables rules
      
    Use `iptables-persistent` to persist these rules; `sudo apt install iptables-persistent`.
    The rules will be saved in `/etc/iptables/rules.v4` and `/etc/iptables/rules.v6`.
    From the rules, you can simply filter out the required rules, and replace the file `/etc/iptables/rules.v4` with the required rules. It might look like this:

    ```ini
    *nat
    -A PREROUTING -i ens192 -p tcp -m tcp --dport 80 -j REDIRECT --to-port 3130
    -A PREROUTING -i ens192 -p tcp -m tcp --dport 443 -j REDIRECT --to-port 3131
    -A POSTROUTING -o ens160 -j MASQUERADE
    COMMIT
    # Completed on Fri Jul 12 10:00:51 2024
    ```


## 3. Machine behind proxy server

> [!NOTE]
> For transparent proxy (aka firewall), we do not need to set any env variables.
> The proxy server will automatically intercept the traffic and forward it to the destination.
> The env variables are required only for explicit proxy.

Create another VM which is connected to only `proxy-segment`. We will be using this as the dev machine for testing proxy scenarios.

Once the machine starts up it should receive an IP address in the range `192.168.0.100-192.168.0.240`.

For using SSL proxy you need to trust the `proxy-ca.crt` file that was generated in the proxy server and included in the squid configuration file.
Copy the CA certificate to the client machine, and trust it. To trust it:
1. [add it to trusted root of the machine][7]
2. Set the environment variable `REQUESTS_CA_BUNDLE=/path/to/proxy-ca.crt`


```bash
# Only for SSL proxy
scp 192.168.0.1:~/arcvmware-util/squid-proxy-setup/files/proxy-ca.crt .
sudo cp proxy-ca.crt /usr/local/share/ca-certificates/ # The trusted-root path can be different, depending on the Linux distro. Check the link above
sudo update-ca-certificates
export REQUESTS_CA_BUNDLE=/usr/local/share/ca-certificates/proxy-ca.crt
```

Assuming the proxy ports were unchanged in `squid.conf`, the proxy server is listening to:
- Non-SSL Proxy: `192.168.0.1:3128`
- SSL Proxy: `192.168.0.1:3129`

Set these environment variables (after replacing the `$values`) in `~/.bashrc`:
```bash
proxy_url="http://$username:$password@$host:$port"
export HTTP_PROXY=$proxy_url
export HTTPS_PROXY=$proxy_url
export FTP_PROXY=$proxy_url
export http_proxy=$proxy_url
export https_proxy=$proxy_url
export ftp_proxy=$proxy_url
export no_proxy='.svc,kubernetes.default.svc,192.168.0.0/24,localhost,127.0.0.0/8,10.96.0.0/12,10.244.0.0/16,10.224.0.0/16'
export NO_PROXY='.svc,kubernetes.default.svc,192.168.0.0/24,localhost,127.0.0.0/8,10.96.0.0/12,10.244.0.0/16,10.224.0.0/16'
```

To pass environment variables during sudo, you can run `sudo -E` 


[1]: https://linuxconfig.org/how-to-configure-static-ip-address-on-ubuntu-18-04-bionic-beaver-linux
[2]: https://www.tecmint.com/set-add-static-ip-address-in-linux/
[3]: https://computingforgeeks.com/install-and-configure-dnsmasq-on-ubuntu/
[4]: https://www.tecmint.com/setup-a-dns-dhcp-server-using-dnsmasq-on-centos-rhel/
[5]: https://www.digitalocean.com/community/tutorials/how-to-install-and-use-docker-on-ubuntu-20-04
[6]: http://en.wikipedia.org/wiki/NCSA_HTTPd
[7]: https://manuals.gfi.com/en/kerio/connect/content/server-configuration/ssl-certificates/adding-trusted-root-certificates-to-the-server-1605.html
[dnsmasq_arch]: https://wiki.archlinux.org/title/dnsmasq
[nat_iptables]: https://www.karlrupp.net/en/computer/nat_tutorial
[exhaustive_iptables_tutorial]: https://rlworkman.net/howtos/iptables/iptables-tutorial.html#TRAVERSINGOFTABLES

### Aside

1. Link contains interesting logformat:
    https://kenmoini.com/post/2024/05/outbound-squid-proxy/

2. Alternative commands for `iptables`. But these commands will break if the IP address of the `internet-segment` interface changes.
    ```bash
    export ifExt=ens160 # The interface connected to the external interface (internet-segment)
    export ifPriv=ens192 # The interface connected to the private network (proxy-segment)
    export http_proxy_port=3130 # The proxy port for http traffic (non-SSL proxy)
    export https_proxy_port=3131 # The proxy port for https traffic (SSL proxy)
    export external_ip=$(ip addr show dev $ifExt | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
    sudo iptables -t nat -A PREROUTING -i $ifPriv -p tcp --dport 80 -j DNAT --to $external_ip:$http_proxy_port
    sudo iptables -t nat -A PREROUTING -i $ifPriv -p tcp --dport 443 -j DNAT --to $external_ip:$https_proxy_port
    sudo iptables -t nat -A POSTROUTING -o $ifExt -j MASQUERADE
    ```

3. You can also export and import the iptables rules using the following commands:
    ```bash
    iptables-save > /my/ip-rules.conf
    iptables-restore < /my/ip-rules.conf
    ```

<details>
    <summary>How to connect through a Jumpserver to a VM inside private network</summary>

- 100.101.102.103 : IP of the jumpserver (eg, where tailscale is installed)

- 172.17.100.101: IP of the transparent proxy server / router VM (connected to both public and private network). It's internal IP is 192.68.0.1

- 192.168.0.100: IP of the client VM inside the private network

**on the jumpserver (IP: 100.101.102.103)**

```bash
sudo iptables -t nat -A PREROUTING -i tailscale0 -p tcp --dport 2222 -j DNAT --to-destination 172.17.100.101:2222
```

**on the proxy server / router of private network (IP: 172.17.100.101)**

```bash
sudo iptables -t nat -A PREROUTING -i ens160 -p tcp --dport 2222 -j DNAT --to-destination 192.168.0.100:22
```

Now we can ssh into the client VM from the jumpserver using the command:

```bash
ssh -p 2222 arcvmware@100.101.102.103
```

</details>
