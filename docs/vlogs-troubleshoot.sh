#!/bin/bash
#
# Victoria Logs Troubleshooting Helper
# ====================================
# Query Victoria Logs via the official HTTP API.
#
# API reference:   https://docs.victoriametrics.com/victorialogs/querying/
# LogsQL reference: https://docs.victoriametrics.com/victorialogs/logsql/
#
# Correct endpoint: POST /select/logsql/query
#                   body: query=<LogsQL expression>   (form-encoded)
# Response format:  JSONL — one JSON object per line, e.g.:
#   {"_time":"2026-03-01T12:00:00Z","_stream":"{pod=\"sonarr-0\"}","_msg":"..."}
#
# Core fields always present in every log entry:
#   _time    RFC3339 timestamp
#   _msg     the raw log message
#   _stream  stream label set as a string, e.g. {namespace="media",pod="sonarr-0"}
#
# Kubernetes metadata field names (exact names depend on Vector config):
#   Run: ./vlogs-troubleshoot.sh fields   — to discover what's actually indexed.
#
# Usage:
#   ./vlogs-troubleshoot.sh [command] [args...]
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — override via environment variables
# ---------------------------------------------------------------------------

VLOGS_URL="${VLOGS_URL:-http://logs.homelab}"   # ingress; falls back to port-forward
NAMESPACE="${NAMESPACE:-media}"
LIMIT="${LIMIT:-50}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Connection management
# ---------------------------------------------------------------------------

PORT_FWD_PID=""

cleanup() {
    [[ -n "$PORT_FWD_PID" ]] && kill "$PORT_FWD_PID" 2>/dev/null || true
}
trap cleanup EXIT

ensure_connection() {
    if curl -sf --max-time 3 "${VLOGS_URL}/metrics" >/dev/null 2>&1; then
        return 0
    fi
    echo -e "${YELLOW}Cannot reach ${VLOGS_URL}, starting port-forward to victoria-logs...${NC}" >&2
    kubectl port-forward -n victoria-logs svc/victoria-logs 9428:9428 >/dev/null 2>&1 &
    PORT_FWD_PID=$!
    VLOGS_URL="http://localhost:9428"
    local attempts=0
    while ! curl -sf --max-time 1 "${VLOGS_URL}/metrics" >/dev/null 2>&1; do
        sleep 1
        (( attempts++ ))
        if (( attempts > 10 )); then
            echo -e "${RED}Failed to connect to Victoria Logs${NC}" >&2
            exit 1
        fi
    done
    echo -e "${GREEN}Port-forward active at http://localhost:9428${NC}" >&2
}

# ---------------------------------------------------------------------------
# Core query — streams JSONL to stdout
# Usage: run_query "<LogsQL>" [limit]
# ---------------------------------------------------------------------------

run_query() {
    local logsql="$1"
    local limit="${2:-$LIMIT}"
    ensure_connection
    # --data-urlencode handles all special characters correctly
    curl -sf "${VLOGS_URL}/select/logsql/query" \
        --data-urlencode "query=${logsql}" \
        -d "limit=${limit}"
}

# Format JSONL as: [timestamp] message
fmt_lines() {
    # Each line from the API is a separate JSON object; pipe each through jq
    jq -r '"[" + ._time + "] " + ._msg'
}

# Format JSONL as: [timestamp] [stream] message
fmt_lines_verbose() {
    jq -r '"[" + ._time + "] " + ._stream + " " + ._msg'
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

# fields — Discover indexed field names (ALWAYS run this first)
cmd_fields() {
    local time_range="${1:-1h}"
    echo -e "${BLUE}=== Indexed field names (last ${time_range}) ===${NC}"
    echo -e "${YELLOW}These are the actual field names you can use in stream filters and queries.${NC}"
    echo ""
    ensure_connection
    curl -sf "${VLOGS_URL}/select/logsql/field_names" \
        --data-urlencode "query=_time:${time_range}" \
      | jq -r '.values | sort_by(-.hits)[] | "\(.hits)\t\(.value)"' \
      | column -t
}

# streams — List active log streams with hit counts
cmd_streams() {
    local time_range="${1:-1h}"
    echo -e "${BLUE}=== Active streams (last ${time_range}) ===${NC}"
    ensure_connection
    curl -sf "${VLOGS_URL}/select/logsql/streams" \
        --data-urlencode "query=_time:${time_range}" \
        -d "limit=50" \
      | jq -r '.values | sort_by(-.hits)[] | "\(.hits)\t\(.value)"' \
      | column -t
}

# errors — Find error/fatal/panic logs
cmd_errors() {
    local time_range="${1:-1h}"
    local extra="${2:-}"
    local query="_time:${time_range} i(error) OR i(fatal) OR i(panic)"
    [[ -n "$extra" ]] && query="${query} AND ${extra}"

    echo -e "${RED}=== Errors/Fatal/Panic (last ${time_range}) ===${NC}"
    [[ -n "$extra" ]] && echo "  Extra filter: ${extra}"
    echo ""
    run_query "$query" 100 | fmt_lines_verbose
}

# top — Show noisiest streams
cmd_top() {
    local time_range="${1:-1h}"
    local n="${2:-10}"
    echo -e "${BLUE}=== Top ${n} noisiest log streams (last ${time_range}) ===${NC}"
    run_query "_time:${time_range} | stats by (_stream) count() hits | sort by (hits desc) | limit ${n}" 200 \
      | jq -r '"\(.hits)\t\(._stream)"' \
      | column -t
}

# tail — Live stream via /select/logsql/tail
cmd_tail() {
    local filter="${1:-*}"
    echo -e "${GREEN}=== Live tail (Ctrl+C to stop): ${filter} ===${NC}"
    ensure_connection
    # -N disables curl output buffering so lines appear immediately
    curl -N -sf "${VLOGS_URL}/select/logsql/tail" \
        --data-urlencode "query=${filter}" \
        -d "start_offset=30s" \
      | jq -r '"[" + ._time + "] " + ._stream + " " + ._msg'
}

# stats — Log volume over time (hit counts per bucket)
cmd_stats() {
    local filter="${1:-*}"
    local step="${2:-5m}"
    local time_range="${3:-1h}"
    echo -e "${BLUE}=== Log volume: '${filter}' over last ${time_range} (${step} buckets) ===${NC}"
    ensure_connection
    curl -sf "${VLOGS_URL}/select/logsql/hits" \
        --data-urlencode "query=${filter}" \
        -d "start=${time_range}" \
        -d "end=now" \
        -d "step=${step}" \
      | jq -r '
          .hits[0] |
          [.timestamps, .values] |
          transpose[] |
          .[0] + "\t" + (.[1] | tostring)
        ' \
      | column -t
}

# query — Raw LogsQL passthrough, pretty-printed
cmd_query() {
    local logsql="$1"
    local limit="${2:-$LIMIT}"
    echo -e "${BLUE}=== Query: ${logsql} ===${NC}"
    echo ""
    run_query "$logsql" "$limit" | jq -r '"[" + ._time + "] " + ._msg'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    local cmd="${1:-help}"
    case "$cmd" in
        fields)
            cmd_fields "${2:-1h}"
            ;;
        streams)
            cmd_streams "${2:-1h}"
            ;;
        errors)
            cmd_errors "${2:-1h}" "${3:-}"
            ;;
        top)
            cmd_top "${2:-1h}" "${3:-10}"
            ;;
        tail)
            cmd_tail "${2:-*}"
            ;;
        stats)
            cmd_stats "${2:-*}" "${3:-5m}" "${4:-1h}"
            ;;
        query|q)
            [[ -z "${2:-}" ]] && { echo "Usage: $0 query '<logsql>' [limit]"; exit 1; }
            cmd_query "$2" "${3:-$LIMIT}"
            ;;
        help|--help|-h|"")
            cat <<'HELP'
Victoria Logs Troubleshooting CLI
==================================

API reference:  https://docs.victoriametrics.com/victorialogs/querying/
LogsQL syntax:  https://docs.victoriametrics.com/victorialogs/logsql/

Endpoint: POST /select/logsql/query  (body: query=<LogsQL>, form-encoded)
Response: JSONL stream — one JSON object per line (NOT a JSON array)

Core fields in every log entry:
  _time    RFC3339 timestamp
  _msg     the log message
  _stream  stream label set, e.g. {namespace="media",pod="sonarr-0"}

Usage: ./vlogs-troubleshoot.sh <command> [args...]

Commands:

  fields [time_range]
    Discover all indexed field names and their hit counts.
    Run this FIRST to learn the exact Kubernetes metadata field names.
    Example: ./vlogs-troubleshoot.sh fields 6h

  streams [time_range]
    List active log streams with hit counts.
    Use these stream values in {}-style stream filters.
    Example: ./vlogs-troubleshoot.sh streams 1h

  errors [time_range] [extra_logsql_filter]
    Find error/fatal/panic logs with optional extra filter.
    Example: ./vlogs-troubleshoot.sh errors 2h
    Example: ./vlogs-troubleshoot.sh errors 1h 'sonarr'

  top [time_range] [n]
    Show the N noisiest log streams.
    Example: ./vlogs-troubleshoot.sh top 1h 10

  tail [logsql_filter]
    Live-stream logs as they arrive (Ctrl+C to stop).
    Example: ./vlogs-troubleshoot.sh tail '*'
    Example: ./vlogs-troubleshoot.sh tail 'error'

  stats [filter] [step] [time_range]
    Show log volume over time, grouped by time buckets.
    Example: ./vlogs-troubleshoot.sh stats 'error' 5m 2h

  query '<logsql>' [limit]
    Execute a raw LogsQL query. Output: [time] message
    Example: ./vlogs-troubleshoot.sh query '_time:15m error | sort by (_time)'
    Example: ./vlogs-troubleshoot.sh query '_time:5m | top 10 by (_stream)'

Environment Variables:
  VLOGS_URL    Base URL (default: http://logs.homelab)
               Falls back to kubectl port-forward if unreachable.
  NAMESPACE    Default namespace hint (default: media)
  LIMIT        Max results per query (default: 50)

Useful LogsQL patterns (adjust field names after running 'fields'):
  All logs last 5 min:         _time:5m
  Case-insensitive errors:     _time:1h i(error)
  Stream filter by namespace:  {namespace="media"} _time:15m
  Stream filter by pod:        {pod=~"sonarr.*"} _time:15m
  Count by stream:             _time:1h | stats by (_stream) count() hits
  Top noisy pods:              _time:1h | top 10 by (_stream)
  Facets (field value counts): use /select/logsql/facets endpoint

HELP
            ;;
        *)
            echo "Unknown command: $cmd. Run '$0 help' for usage." >&2
            exit 1
            ;;
    esac
}

main "$@"
