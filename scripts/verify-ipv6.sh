#!/usr/bin/env bash
# Verify IPv6 egress after assigning a global IPv6 address to the instance's ENI.
# Run on the EC2 host itself (not inside a container).
set -uo pipefail

echo "=== IPv6 routes ==="
ip -6 route

echo "=== Reachability test to smtp.gmail.com:465 over IPv6/IPv4 ==="
curl -v --connect-timeout 5 telnet://smtp.gmail.com:465
