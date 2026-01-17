#!/usr/bin/env bash
set -euo pipefail

# Requires: kubectl, jq
# Output columns: NAMESPACE/NAME	PEERS	CONNECTED	LASTSYNC	PEER_LIST

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 2
fi

# Use current kubeconfig context and query all ReplicationSource objects
kubectl get replicationsource --all-namespaces -o json | jq -r '
  .items[] |
  {
    ns: .metadata.namespace,
    name: .metadata.name,
    peersSpec: (.spec.syncthing.peers // []),
    peersStatus: (.status.syncthing.peers // []),
    lastSync: (.status.lastSyncStartTime // .status.syncthing.lastScanTime // "N/A")
  } |
  (
    . as $x |
    ($x.peersSpec | length) as $peercount |
    ($x.peersStatus | map(select(.connected==true)) | length) as $connectedCount |
    {ns:$x.ns, name:$x.name, peercount:$peercount, connected:($connectedCount>0), lastSync:$x.lastSync, peerList:($x.peersStatus // $x.peersSpec | map( ( .ID // "-" ) + "@" + ( .address // "-" ) + "@connected=" + ((.connected // false) | tostring) ) ) }
  ) |
  ("\(.ns)/\(.name)\tPEERS=\(.peercount)\tCONNECTED=\(.connected)\tLASTSYNC=\(.lastSync)\tPEER_LIST=\(.peerList|join(";"))")'

exit 0
