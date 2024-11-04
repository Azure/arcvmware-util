#!/bin/bash

#######################
# Configurable Variables
#######################
# Interface names (if not provided, will be auto-detected)
PUBLIC_INTERFACE=""
PRIVATE_INTERFACE=""

# Proxy ports
HTTP_PROXY_PORT=3130
HTTPS_PROXY_PORT=3131

#######################
# Interface Detection Functions
#######################
get_public_interface() {
    if [ -n "$PUBLIC_INTERFACE" ]; then
        echo "$PUBLIC_INTERFACE"
        return
    fi
    ip route | grep '^default' | awk '{print $5}'
}

get_private_interface() {
    local public_if="$1"
    
    if [ -n "$PRIVATE_INTERFACE" ]; then
        echo "$PRIVATE_INTERFACE"
        return
    fi

    mapfile -t possible_private < <(ip link show | 
                                   grep -E "^[0-9]+: (eth|ens)" | 
                                   awk -F': ' '{print $2}' | 
                                   cut -d'@' -f1 | 
                                   grep -v "$public_if" | 
                                   grep -v "lo")

    if [ "${#possible_private[@]}" -eq 0 ]; then
        echo "Error: No possible private interfaces found" >&2
        exit 1
    elif [ "${#possible_private[@]}" -gt 1 ]; then
        echo "Error: Multiple possible private interfaces found: ${possible_private[*]}" >&2
        echo "Please set PRIVATE_INTERFACE manually" >&2
        exit 1
    fi

    echo "${possible_private[0]}"
}

#######################
# Main Script
#######################
# Get interfaces
ifExt=$(get_public_interface)
if [ -z "$ifExt" ]; then
    echo "Error: Could not detect public interface"
    exit 1
fi

ifPriv=$(get_private_interface "$ifExt")
if [ -z "$ifPriv" ]; then
    echo "Error: Could not detect private interface"
    exit 1
fi

# Check if nftables is installed (available as sudo command)
if ! sudo nft -v &> /dev/null; then
    echo "Error: nftables is not installed or not available in PATH" >&2
    exit 1
fi


# Print detected interfaces
echo "Using public interface: $ifExt"
echo "Using private interface: $ifPriv"

# Create nftables configuration
cat << EOF | sudo nft -f -
flush ruleset

table ip nat {
    chain prerouting {
        type nat hook prerouting priority -100;

        # HTTP/HTTPS proxy redirections
        iif "$ifPriv" tcp dport 80 redirect to :$HTTP_PROXY_PORT
        iif "$ifPriv" tcp dport 443 redirect to :$HTTPS_PROXY_PORT
    }

    chain postrouting {
        type nat hook postrouting priority 100;
        
        # Masquerade outgoing traffic
        oif "$ifExt" masquerade
    }
}

table ip filter {
    chain forward {
        type filter hook forward priority 0; policy drop;

        # ICMP rules
        iif "$ifPriv" oif "$ifExt" ip protocol icmp accept
        iif "$ifExt" oif "$ifPriv" ip protocol icmp accept

        # DNS rules (UDP)
        iif "$ifPriv" oif "$ifExt" udp dport 53 accept
        iif "$ifExt" oif "$ifPriv" udp sport 53 accept

        # DNS rules (TCP)
        iif "$ifPriv" oif "$ifExt" tcp dport 53 accept
        iif "$ifExt" oif "$ifPriv" tcp sport 53 accept
    }
}
EOF

# Display rules
echo "Displaying current nftables ruleset..."
sudo nft list ruleset
sudo bash -c 'nft list ruleset > /etc/nftables.conf'
sudo systemctl enable nftables
sudo systemctl start nftables
