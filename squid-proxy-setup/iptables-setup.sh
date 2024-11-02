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

# Print detected interfaces
echo "Using public interface: $ifExt"
echo "Using private interface: $ifPriv"

# Clear existing rules
sudo iptables -F
sudo iptables -t nat -F
sudo iptables -P FORWARD DROP
sudo iptables -P INPUT ACCEPT
sudo iptables -P OUTPUT ACCEPT

# NAT configuration
sudo iptables -t nat -A POSTROUTING -o "$ifExt" -j MASQUERADE

# ICMP rules
sudo iptables -A FORWARD -i "$ifPriv" -o "$ifExt" -p icmp -j ACCEPT
sudo iptables -A FORWARD -i "$ifExt" -o "$ifPriv" -p icmp -j ACCEPT

# DNS rules
sudo iptables -A FORWARD -i "$ifPriv" -o "$ifExt" -p udp --dport 53 -j ACCEPT
sudo iptables -A FORWARD -i "$ifExt" -o "$ifPriv" -p udp --sport 53 -j ACCEPT
sudo iptables -A FORWARD -i "$ifPriv" -o "$ifExt" -p tcp --dport 53 -j ACCEPT
sudo iptables -A FORWARD -i "$ifExt" -o "$ifPriv" -p tcp --sport 53 -j ACCEPT

# Proxy redirections
sudo iptables -t nat -A PREROUTING -i "$ifPriv" -p tcp --dport 80 -j REDIRECT --to-port "$HTTP_PROXY_PORT"
sudo iptables -t nat -A PREROUTING -i "$ifPriv" -p tcp --dport 443 -j REDIRECT --to-port "$HTTPS_PROXY_PORT"

# Display rules
echo "Displaying current iptables rules..."
sudo iptables -L -n -v
echo -e "\nDisplaying NAT rules..."
sudo iptables -t nat -L -n -v
