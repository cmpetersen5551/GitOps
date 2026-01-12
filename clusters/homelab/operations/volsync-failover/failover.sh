#!/bin/sh
set -eu
# Local convenience script (mirror of ConfigMap's script). Use for local testing.
exec /etc/volsync-failover/failover.sh "$@"
