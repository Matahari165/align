#!/bin/sh
set -eu

usage() {
    echo "usage: $0 PID [duration_seconds] [interval_seconds]" >&2
    echo "       CPU is the macOS ps percentage of one logical CPU; RSS is MiB." >&2
    exit 2
}

if [ "$#" -lt 1 ]; then
    usage
fi
pid=$1
duration=${2:-300}
interval=${3:-2}

case "$pid" in
    ''|*[!0-9]*) usage ;;
esac

awk -v duration="$duration" -v interval="$interval" 'BEGIN {
    if (duration <= 0 || interval <= 0) exit 1
}' || usage

sample_file=$(mktemp "${TMPDIR:-/tmp}/align-process-metrics.XXXXXX")
trap 'rm -f "$sample_file"' EXIT HUP INT TERM

printf 'timestamp,elapsed_seconds,cpu_percent,rss_mib\n'
printf 'timestamp,elapsed_seconds,cpu_percent,rss_mib\n' > "$sample_file"

started_at=$(date +%s)
while :; do
    now=$(date +%s)
    elapsed=$((now - started_at))
    [ "$elapsed" -ge "$duration" ] && break

    metrics=$(ps -p "$pid" -o %cpu= -o rss= | awk 'NR == 1 { print $1, $2 }') || true
    if [ -z "$metrics" ]; then
        echo "process $pid is no longer running" >&2
        break
    fi

    set -- $metrics
    cpu=$1
    rss_kib=$2
    rss_mib=$(awk -v kib="$rss_kib" 'BEGIN { printf "%.2f", kib / 1024 }')
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    row="$timestamp,$elapsed,$cpu,$rss_mib"
    printf '%s\n' "$row"
    printf '%s\n' "$row" >> "$sample_file"
    sleep "$interval"
done

awk -F, '
    NR == 1 { next }
    {
        samples += 1
        cpuSum += $3
        rssSum += $4
        if (samples == 1 || $3 > cpuMax) cpuMax = $3
        if (samples == 1 || $4 > rssMax) rssMax = $4
        if (samples == 1) rssInitial = $4
        rssFinal = $4
    }
    END {
        if (samples == 0) {
            print "summary: no samples" > "/dev/stderr"
            exit 0
        }
        printf "summary: samples=%d cpu_avg=%.2f%% cpu_max=%.2f%% rss_initial=%.2fMiB rss_avg=%.2fMiB rss_max=%.2fMiB rss_delta=%.2fMiB\n",
            samples, cpuSum / samples, cpuMax, rssInitial, rssSum / samples, rssMax, rssFinal - rssInitial > "/dev/stderr"
    }
' "$sample_file"
