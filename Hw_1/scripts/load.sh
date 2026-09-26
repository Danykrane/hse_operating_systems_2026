#!/bin/bash
# load.sh MODE N [SECONDS=180] - запустить в фоне N источников нагрузки одного вида.
#
#   user     N x «bc -l» считает pi до 100000 знаков        - счет в режиме пользователя
#   sys      N x «dd if=/dev/zero of=/dev/null bs=1m»       - работа внутри ядра
#   nice     как user, но через «nice -n 20»                - минимальный приоритет
#   bg       как user, но через «taskpolicy -c background»  - QoS background, только E-ядра
#   threads  1 процесс build/threads с N потоками           - LA считает потоки
#   io       N x build/iowait                               - ожидание диска (состояние U)
#   sleep    N x «sleep»                                    - спящие процессы (состояние S)
#
# load.sh stop - остановить всю запущенную нагрузку.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
pidfile=${TMPDIR:-/tmp}/hw1-load.pids

mode=${1:?"usage: $0 user|sys|nice|bg|threads|io|sleep N [seconds] | stop"}
if [ "$mode" = stop ]; then
    [ -f "$pidfile" ] && kill $(cat "$pidfile") 2> /dev/null || true
    rm -f "$pidfile" "${TMPDIR:-/tmp}"/hw1-io.*
    exit 0
fi
n=${2:-10}
secs=${3:-180}
[ "$mode" = threads ] && count=1 || count=$n

pi='scale=100000; 4*a(1)'   # pi через арктангенс: долгий чистый счет
pids=()
for i in $(seq "$count"); do
    case $mode in
        user)    bc -l <<< "$pi" > /dev/null & ;;
        sys)     dd if=/dev/zero of=/dev/null bs=1m 2> /dev/null & ;;
        nice)    nice -n 20 bc -l <<< "$pi" > /dev/null & ;;
        bg)      taskpolicy -c background bc -l <<< "$pi" > /dev/null & ;;
        threads) "$root/build/threads" "$n" "$secs" & ;;
        io)      "$root/build/iowait" "${TMPDIR:-/tmp}/hw1-io.$i" "$secs" > /dev/null & ;;
        sleep)   sleep "$secs" & ;;
        *)       echo "unknown mode: $mode" >&2; exit 1 ;;
    esac
    pids+=($!)
done

echo "${pids[@]}" >> "$pidfile"
(sleep "$secs"; kill "${pids[@]}" 2> /dev/null) > /dev/null 2>&1 &
echo "load.sh: $mode x $n на $secs с, PID: ${pids[*]}"
