
### Context

There is one AVS customer whose VCenter IP address (`10.244.0.2`) falls in the appliance pod CIDR range (`10.244.0.0/16`). That caused the routing inside the appliance VM into thinking that `10.244.0.2` is an address inside the pod network, and the traffic could not be routed out of the appliance VM.

## Solution Approach

If we can use a virtual IP for the vCenter, which is outside the `10.244.*` range, then the routing issue can be resolved.

We need to select some IP address which is not already used in any Segments. For example, in the AVS setup `VMWAREAVS-arcprivatecloudsfte`, the RFC 1918 addresses which are used / not used are as follows:

1. `10.0.0.0/8` : Used by AVS
   ![avs_connectivty_address_block_for_private_cloud.jpg](./assets/avs_10_0_0_0.jpg)

2. `172.16.0.0/12`: Used / will be used by the segments
    ![avs_nsx_segments.jpg](./assets/nsx_172_16_0_0.jpg)

3. `192.168.0.0/16`: Not used in AVS - only used in isolated networks (example proxy network setup).

Hence, we can use an IP address from `192.168.0.0/16` as the VIP.
TODO: Test what happens when we try reaching `192.168.0.0/16` from a VM inside an isolated network.

## Unsuccessful Attempt - DNAT

<details>

<summary>Click to view details</summary>

We tried adding a DNAT rule in the NSX-T NAT so that packets destined to `192.168.0.2` are DNATed to `10.0.0.2`. However, the following happens:
1. After leaving the source machine, destination `192.168.0.2` is translated to `10.0.0.2`.
2. VCenter receives the packet and does `ACK`.
3. The `ACK` packet is sent back to the source machine. However, `10.0.0.2` is not translated back to `192.168.0.2` before reaching the source machine. Hence, the source machine drops the packet (TCP RST).

We don't know the actual reason for this yet.

![avs_nsx_failed_nat.jpg](./assets/failed_nat.jpg)

</details>

## Successful Attempt - L7 Load Balancer

We can use the NSX-T L7 Load Balancer to achieve the same. The steps are as follows:

1. Create a server pool. (let the name be `vc-server-pool`)

    **Set SNAT Translation Mode to `Disabled`. The default is `Automap`.**

    > Automap means that the source IP address of the packet is translated to the IP address of the load balancer.
    > Disabled means that the source IP address of the packet is not translated.

    Since, we are using a virtual IP for the Load Balancer, which does not exist in the AVS, we should not translate the Source IP address of the packet to the Load Balancer IP address. If we map it, then the ACK packets from the VCenter will be sent to the Load Balancer IP address which does not exist, and we will get 504 Gateway Timeout error.

    ![01_server_pool.jpg](./assets/01_server_pool.jpg)

2. Add members to the server pool. In this case, we have only one member which is the VCenter IP address: `10.0.0.2`.

    ![02_server_pool_members.jpg](./assets/02_server_pool_members.jpg)

3. Create the load balancer (let the name be `vc-lb`)

    ![03_load_balancer.jpg](./assets/03_load_balancer.jpg)

4. The communication to the vCenter happens on port 443. Hence we need some SSL certificate to be present on the load balancer. We can generate and use a self-signed certificate for this purpose in the NSX-T Manager.

    ![04_cert_generate.jpg](./assets/04_cert_generate.jpg)

    ![05_cert_details.jpg](./assets/05_cert_details.jpg)

5. Create a virtual server. The virtual server is the virtual IP address which the clients will use to connect to the vCenter. In this case, it is `192.168.0.2`.
    - IP Address: `192.168.0.2`
    - Port: `443`
    - Load Balancer: `vc-lb` (from step 3)
    - Server Pool: `vc-server-pool` (from step 1)

    ![06_virtual_server.jpg](./assets/06_virtual_server.jpg)

6. Click on `SSL Configuration`, enable both Client and Server SSL, and select the certificate which we created in step 4.

    ![07_ssl_client.jpg](./assets/07_ssl_client.jpg)

    ![08_ssl_server.jpg](./assets/08_ssl_server.jpg)

7. Now, we can access the vCenter using the virtual IP address `192.168.0.2`.

    ```sh
    curl -vI -k https://192.168.0.2
    *   Trying 192.168.0.2:443...
    * Connected to 192.168.0.2 (192.168.0.2) port 443
    * ALPN: curl offers h2,http/1.1
    ...
    * TLSv1.2 (OUT), TLS handshake, Finished (20):
    * TLSv1.2 (IN), TLS handshake, Finished (20):
    * SSL connection using TLSv1.2 / ECDHE-RSA-AES128-GCM-SHA256 / prime256v1 / rsaEncryption
    * ALPN: server accepted http/1.1
    * Server certificate:
    *  subject: CN=vc-load-balancer-cert; C=US
    *  start date: Oct 29 14:09:24 2024 GMT
    *  expire date: Feb  1 14:09:24 2027 GMT
    *  issuer: CN=vc-load-balancer-cert; C=US
    *  SSL certificate verify result: self-signed certificate (18), continuing anyway.
    *   Certificate level 0: Public key type RSA (2048/112 Bits/secBits), signed using sha256WithRSAEncryption
    * using HTTP/1.x
    > HEAD / HTTP/1.1
    > Host: 192.168.0.2
    > User-Agent: curl/8.5.0
    > Accept: */*
    >
    < HTTP/1.1 200 OK
    HTTP/1.1 200 OK
    ...
    ```