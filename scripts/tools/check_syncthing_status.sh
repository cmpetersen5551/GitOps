
#!/usr/bin/env bash
set -euo pipefail

# Requires: kubectl, jq
# Outputs a simple table:
# Service\tConnected\tLast Sync Time

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 2
fi

NS_FLAG="--all-namespaces"

# Fetch ReplicationSource objects and output one line per ReplicationSource
raw_output=$(kubectl get replicationsource $NS_FLAG -o json | jq -r '
  .items[] |
  [
    .metadata.namespace,
    .metadata.name,
    (.metadata.name | sub("-(primary|backup)$"; "")),
    ((.status.syncthing.peers // []) | length),
    ((.status.syncthing.peers // []) | map(select(.connected==true)) | length),
    (.status.lastSyncStartTime // .status.syncthing.lastScanTime // "N/A"),
    (.status.lastSyncCompletionTime // .status.lastSyncEndTime // "N/A"),
    ((.status.conditions // []) | map(select(.type=="Synchronizing"))[0].status // "Unknown"),
    ((.status.conditions // []) | map(select(.type=="Synchronizing"))[0].reason // ""),
    ((.status.conditions // []) | map(select(.type=="Synchronizing"))[0].message // "")
  ] | @tsv')

lines=()
if [[ -n "$raw_output" ]]; then
  while IFS= read -r l; do
    lines+=("$l")
  done <<< "$raw_output"
fi

services=()
connected_values=()
laststart_values=()
lastcomplete_values=()

for l in "${lines[@]}"; do
  # fields: namespace, name, base, peers_total, peers_connected, lastSyncStart, lastSyncComplete, syncStatus, syncReason, syncMessage
  IFS=$'\t' read -r ns name base peers_total peers_connected laststart lastcomplete syncstatus syncreason syncmessage <<< "$l"
  svc="$base"

  # determine connected boolean from peers_connected
  if [[ "$peers_connected" -gt 0 ]]; then
    connval="true"
  else
    connval="false"
  fi

  # find index
  idx=-1
  for i in "${!services[@]}"; do
    if [[ "${services[i]}" == "$svc" ]]; then
      idx=$i
      break
    fi
  done

  if [[ $idx -eq -1 ]]; then
    # append
    services+=("$svc")
    connected_values+=("$connval")
    # store both start and complete values (use N/A when missing)
    if [[ -n "$laststart" && "$laststart" != "N/A" ]]; then
      laststart_values+=("$laststart")
    else
      laststart_values+=("N/A")
    fi
    if [[ -n "$lastcomplete" && "$lastcomplete" != "N/A" ]]; then
      lastcomplete_values+=("$lastcomplete")
    else
      lastcomplete_values+=("N/A")
    fi
  else
    # update connected -> true if any source reports true
    if [[ "$connval" == "true" || "${connected_values[$idx]}" == "true" ]]; then
      connected_values[$idx]="true"
    fi
    # update laststart to most recent
    prev_start="${laststart_values[$idx]}"
    if [[ -n "$laststart" && "$laststart" != "N/A" ]]; then
      if [[ -z "$prev_start" || "$prev_start" == "N/A" || "$laststart" > "$prev_start" ]]; then
        laststart_values[$idx]="$laststart"
      fi
    fi
    # update lastcomplete to most recent
    prev_complete="${lastcomplete_values[$idx]}"
    if [[ -n "$lastcomplete" && "$lastcomplete" != "N/A" ]]; then
      if [[ -z "$prev_complete" || "$prev_complete" == "N/A" || "$lastcomplete" > "$prev_complete" ]]; then
        lastcomplete_values[$idx]="$lastcomplete"
      fi
    fi
  fi
done

# Print timestamp, header and rows
now=$(date +"%Y-%m-%dT%H:%M:%S%z")
printf "Checked: %s\n" "$now"
printf "%-20s %-10s %-25s %s\n" "Service" "Connected" "Last Sync Start" "Last Sync Complete"
for i in "${!services[@]}"; do
  printf "%-20s %-10s %-25s %s\n" "${services[i]}" "${connected_values[i]}" "${laststart_values[i]:-N/A}" "${lastcomplete_values[i]:-N/A}"
done | sort

exit 0
