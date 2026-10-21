#!/usr/bin/env bash
# who-is-eating-my-server - plain words on what is using this server right now.
# Maintained by Pro Gineous (https://progineous.com). MIT licensed.
set -euo pipefail

VERSION="1.0.0"
TOP=5
SAMPLE=2
COLOR=1
DISK_PATH=/
SKIP_DU=0

usage() {
  cat <<USAGE
who-is-eating-my-server $VERSION
Shows what is using CPU, RAM, disk I/O, disk space and network right now, with
the process name and, where possible, the systemd service or container behind it.
Read-only.

Usage: who-is-eating-my-server.sh [options]

Options:
  -n, --top N        Show N offenders per section (default $TOP)
  -s, --sample SEC   Sampling window for CPU, I/O and network (default $SAMPLE)
  -p, --path DIR     Where to look for the largest directories (default /)
  --no-du            Skip the largest directories scan (it can be slow on big disks)
  --no-color         Plain output (also honoured: NO_COLOR)
  -h, --help         Show this help
  -V, --version      Show version

Run with sudo to see I/O and network for processes owned by other users.
USAGE
}

need_arg() { [[ $# -ge 2 && -n "$2" ]] || { echo "$1 needs a value" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--top) need_arg "$@"; TOP=$2; shift ;;
    -s|--sample) need_arg "$@"; SAMPLE=$2; shift ;;
    -p|--path) need_arg "$@"; DISK_PATH=$2; shift ;;
    --no-du) SKIP_DU=1 ;;
    --no-color) COLOR=0 ;;
    -h|--help) usage; exit 0 ;;
    -V|--version) echo "who-is-eating-my-server $VERSION"; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done
[[ "$TOP" =~ ^[0-9]+$ && "$SAMPLE" =~ ^[0-9]+$ && $SAMPLE -ge 1 ]] || { echo "--top and --sample take whole numbers" >&2; exit 2; }
[[ -d "$DISK_PATH" ]] || { echo "No such directory: $DISK_PATH" >&2; exit 2; }

[[ -n "${NO_COLOR:-}" || ! -t 1 ]] && COLOR=0
if [[ $COLOR -eq 1 ]]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; D=$'\e[2m'; C=$'\e[36m'; N=$'\e[0m'
else
  R=""; G=""; Y=""; B=""; D=""; C=""; N=""
fi
have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n%s%s== %s ==%s\n' "$B" "$C" "$1" "$N"; }
say() { printf '  %s\n' "$*"; }
human_kb() { awk -v k="$1" 'BEGIN { split("KB MB GB TB",u," "); i=1; while (k>=1024 && i<4) {k/=1024; i++} printf (k<10 ? "%.1f %s" : "%.0f %s"), k, u[i] }'; }

declare -A OWNER_CACHE=()
# Map a PID to "systemd service" or "docker container" using its cgroup.
owner_of() {
  local pid=$1 cg="" out=""
  [[ -n "${OWNER_CACHE[$pid]:-}" ]] && { printf '%s' "${OWNER_CACHE[$pid]}"; return; }
  [[ -r /proc/$pid/cgroup ]] && cg=$(cat "/proc/$pid/cgroup" 2>/dev/null || true)
  if [[ "$cg" =~ docker[-/]([0-9a-f]{12}) ]]; then
    local id=${BASH_REMATCH[1]} name=""
    if have docker; then
      name=$(docker inspect --format '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##') || name=""
    fi
    out="container ${name:-$id}"
  elif [[ "$cg" =~ libpod-([0-9a-f]{12}) ]]; then
    out="podman container ${BASH_REMATCH[1]}"
  elif [[ "$cg" =~ /([^/]+\.service) ]]; then
    out="service ${BASH_REMATCH[1]}"
  elif [[ "$cg" =~ /(session-[^/]+\.scope) ]]; then
    out="login ${BASH_REMATCH[1]}"
  fi
  OWNER_CACHE[$pid]=$out
  printf '%s' "$out"
}
label() {
  local pid=$1 name=$2 o
  o=$(owner_of "$pid")
  if [[ -n "$o" ]]; then printf '%s (pid %s, %s)' "$name" "$pid" "$o"; else printf '%s (pid %s)' "$name" "$pid"; fi
}

CPUS=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
printf '\n%swho-is-eating-my-server %s%s  %s%s, %s CPU, up %s%s\n' "$B" "$VERSION" "$N" "$D" "$(hostname)" "$CPUS" \
  "$(uptime -p 2>/dev/null | sed 's/^up //' || echo '?')" "$N"

# ---- take one sample window for CPU, I/O and network ----
read_cpu() { awk '/^cpu / {idle=$5+$6; t=0; for(i=2;i<=NF;i++) t+=$i; print t, idle}' /proc/stat; }
proc_snapshot() {
  local d pid line rest comm key val rb wb
  local -a f
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    { line=$(<"$d/stat"); } 2>/dev/null || continue
    comm=${line#*(}; comm=${comm%)*}; comm=${comm// /_}
    rest=${line##*) }
    read -r -a f <<<"$rest"
    rb=0; wb=0
    if [[ -r "$d/io" ]]; then
      while read -r key val; do
        case "$key" in read_bytes:) rb=$val ;; write_bytes:) wb=$val ;; esac
      done 2>/dev/null <"$d/io" || true
    fi
    # after the comm field: index 11 is utime, 12 is stime
    printf '%s %s %s %s %s\n' "$pid" "$(( ${f[11]:-0} + ${f[12]:-0} ))" "$rb" "$wb" "$comm"
  done
}
net_snapshot() { awk 'NR>2 {sub(/^ +/, ""); n=split($0, a, /[: ]+/); if (n>=10) print a[1], a[2], a[10]}' /proc/net/dev; }

read -r t1 i1 < <(read_cpu)
snap1=$(proc_snapshot)
net1=$(net_snapshot)
ms1=$(date +%s%3N)
sleep "$SAMPLE"
read -r t2 i2 < <(read_cpu)
ms2=$(date +%s%3N)
snap2=$(proc_snapshot)
net2=$(net_snapshot)
# real window, because walking /proc takes time on busy hosts
ELAPSED=$(awk -v a="$ms1" -v b="$ms2" 'BEGIN {e=(b-a)/1000; if (e<=0) e=1; printf "%.3f", e}')
HZ=$(getconf CLK_TCK 2>/dev/null || echo 100)

# pid cpu% readB/s writeB/s
deltas=$(awk -v hz="$HZ" -v s="$ELAPSED" 'NR==FNR {c[$1]=$2; r[$1]=$3; w[$1]=$4; next}
  ($1 in c) {printf "%s %.1f %d %d %s\n", $1, ($2-c[$1])*100/hz/s, ($3-r[$1])/s, ($4-w[$1])/s, $5}' \
  <(printf '%s\n' "$snap1") <(printf '%s\n' "$snap2"))

# ---- CPU ----
section "CPU"
busy=$(awk -v t="$((t2 - t1))" -v i="$((i2 - i1))" 'BEGIN { if (t>0) printf "%d", (t-i)*100/t; else print 0 }')
read -r l1 l5 l15 _ </proc/loadavg
if [[ $busy -ge 80 ]]; then c=$R; elif [[ $busy -ge 50 ]]; then c=$Y; else c=$G; fi
say "Overall the CPU is ${c}${busy}% busy${N} over the last ${ELAPSED%.*}s. Load average $l1 / $l5 / $l15 on $CPUS CPU(s)."
say "${D}Per process, 100% means one full CPU core.${N}"
if awk -v l="$l1" -v n="$CPUS" 'BEGIN {exit !(l > n)}'; then
  say "${Y}Load is higher than the number of CPUs, so work is queueing.${N}"
fi
shown=0
while read -r pid pct _ _ comm; do
  awk -v p="$pct" 'BEGIN {exit !(p >= 1)}' || continue
  say "$(printf '%6s%%  ' "$pct")$(label "$pid" "$comm")"
  shown=$((shown + 1))
done < <(sort -k2 -rn <<<"$deltas" | head -n "$TOP")
[[ $shown -eq 0 ]] && say "Nothing is using more than 1% of a CPU right now."

# ---- Memory ----
section "Memory"
mt=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
ma=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
swt=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
sf=$(awk '/^SwapFree:/ {print $2}' /proc/meminfo)
used_pct=$(( (mt - ma) * 100 / mt ))
if [[ $used_pct -ge 90 ]]; then c=$R; elif [[ $used_pct -ge 75 ]]; then c=$Y; else c=$G; fi
say "${c}${used_pct}% of RAM in use${N}: $(human_kb $((mt - ma))) of $(human_kb "$mt"), $(human_kb "$ma") still available (cache counts as available)."
if [[ $swt -gt 0 ]]; then
  say "Swap: $(human_kb $((swt - sf))) used of $(human_kb "$swt")."
else
  say "No swap configured."
fi
if have ps; then
  while read -r pid rss comm; do
    say "$(printf '%9s  ' "$(human_kb "$rss")")$(label "$pid" "$comm")"
  done < <(ps -eo pid=,rss=,comm= --sort=-rss 2>/dev/null | head -n "$TOP")
else
  say "${D}ps not found, cannot list processes${N}"
fi
if have dmesg && dmesg 2>/dev/null | grep -qi 'out of memory'; then
  say "${R}The kernel log shows the OOM killer has run since boot:${N} $(dmesg 2>/dev/null | grep -i 'killed process' | tail -1 | sed 's/^\[[^]]*\] //')"
fi

# ---- Disk I/O ----
section "Disk I/O"
io_rows=$(awk '$3+$4 > 0 {print $1, $3, $4, $3+$4, $5}' <<<"$deltas" | sort -k4 -rn | head -n "$TOP")
if [[ ! -r /proc/self/io ]]; then
  say "${D}Per-process I/O is not available on this kernel.${N}"
elif [[ -z "$io_rows" ]]; then
  say "No process read or wrote to disk in the last ${SAMPLE}s."
else
  while read -r pid rb wb _ comm; do
    say "read $(printf '%9s/s' "$(human_kb $((rb / 1024)))")  write $(printf '%9s/s' "$(human_kb $((wb / 1024)))")  $(label "$pid" "$comm")"
  done <<<"$io_rows"
fi
[[ $(id -u) -ne 0 ]] && say "${D}Not root: only your own processes are counted for I/O.${N}"
if [[ -r /proc/pressure/io ]]; then
  iop=$(awk '/^some/ {sub("avg10=","",$2); print $2}' /proc/pressure/io)
  say "Processes were stalled waiting on I/O ${iop}% of the time (last 10s)."
fi

# ---- Disk space ----
section "Disk space"
while read -r src size used avail pct mnt; do
  p=${pct%\%}
  if [[ $p -ge 90 ]]; then c=$R; elif [[ $p -ge 80 ]]; then c=$Y; else c=$G; fi
  say "$(printf '%-24s %s%4s%s used, %s free of %s (%s)' "$mnt" "$c" "$pct" "$N" "$(human_kb "$avail")" "$(human_kb "$size")" "$src")"
  : "$used"
done < <(df -Pk -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1' | sort -u -k6,6)
if [[ $SKIP_DU -eq 0 ]] && have du; then
  echo
  say "Largest directories under $DISK_PATH (same filesystem, 3 levels deep):"
  while read -r kb dir; do
    say "$(printf '%9s  %s' "$(human_kb "$kb")" "$dir")"
  done < <( { if have timeout; then timeout 60 du -xk --max-depth=3 "$DISK_PATH" 2>/dev/null; else du -xk --max-depth=3 "$DISK_PATH" 2>/dev/null; fi; } \
            | sort -rn | awk -v p="$DISK_PATH" '$2 != p' | head -n "$TOP" || true)
  [[ $(id -u) -ne 0 ]] && say "${D}Not root: directories you cannot read are left out.${N}"
fi
if have journalctl; then
  j=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]?B?' | head -1 || true)
  [[ -n "$j" && "$j" != 0B ]] && say "systemd journal uses $j (shrink with: sudo journalctl --vacuum-size=200M)."
fi

# ---- Network ----
section "Network"
while read -r ifc rx tx; do
  [[ "$ifc" == lo ]] && continue
  rx1=""; tx1=""
  read -r rx1 tx1 < <(awk -v i="$ifc" '$1==i {print $2, $3}' <<<"$net1") || true
  [[ -z "${rx1:-}" ]] && continue
  rxs=$(awk -v a="$rx1" -v b="$rx" -v e="$ELAPSED" 'BEGIN {printf "%d", (b-a)/e/1024}')
  txs=$(awk -v a="$tx1" -v b="$tx" -v e="$ELAPSED" 'BEGIN {printf "%d", (b-a)/e/1024}')
  [[ $rxs -eq 0 && $txs -eq 0 ]] && continue
  say "$(printf '%-12s in %9s/s   out %9s/s' "$ifc" "$(human_kb "$rxs")" "$(human_kb "$txs")")"
done <<<"$net2"
if have ss; then
  est=$(ss -Htn state established 2>/dev/null | wc -l)
  say "$est established TCP connections."
  say "Processes with the most connections:"
  ss -Htnp state established 2>/dev/null | grep -oE 'users:\(\("[^"]+",pid=[0-9]+' \
    | sed -E 's/users:\(\("([^"]+)",pid=([0-9]+)/\2 \1/' | sort | uniq -c | sort -rn | head -n "$TOP" \
    | while read -r n pid comm; do say "$(printf '%6s conn  ' "$n")$(label "$pid" "$comm")"; done || true
  say "Remote addresses with the most connections:"
  ss -Htn state established 2>/dev/null | awk '{print $4}' | sed -E 's/:[0-9]+$//; s/^\[|\]$//g' \
    | sort | uniq -c | sort -rn | head -n "$TOP" | while read -r n ip; do say "$(printf '%6s conn  %s' "$n" "$ip")"; done || true
else
  say "${D}ss not found (install iproute2) so connections are not listed.${N}"
fi
section "In short"
top_cpu=$(sort -k2 -rn <<<"$deltas" | head -1)
read -r tc_pid tc_pct _ _ tc_comm <<<"$top_cpu"
top_mem=$(ps -eo pid=,rss=,comm= --sort=-rss 2>/dev/null | head -1 || true)
read -r tm_pid tm_rss tm_comm <<<"$top_mem"
root_pct=$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')
say "CPU is ${busy}% busy; the biggest user is $(label "$tc_pid" "$tc_comm") at ${tc_pct}% of one CPU."
[[ -n "${tm_pid:-}" ]] && say "RAM is ${used_pct}% used; the biggest user is $(label "$tm_pid" "$tm_comm") with $(human_kb "$tm_rss")."
say "The root disk is ${root_pct}% full."
if [[ $busy -lt 50 && $used_pct -lt 75 && $root_pct -lt 80 ]]; then
  say "${G}Nothing looks overloaded right now.${N}"
else
  say "${Y}Start with the sections marked in yellow or red above.${N}"
fi
printf '\n%sSampled over %ss. Nothing was changed.%s\n\n' "$D" "$SAMPLE" "$N"
