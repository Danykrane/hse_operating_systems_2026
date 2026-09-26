#!/bin/bash
# snapshot.sh - снимок загрузки: uptime, второй замер top (в первом %CPU процессов еще не посчитан),
# загрузка по ядрам (build/cpustat) и процессы нагрузки, запущенной через load.sh.
root=$(cd "$(dirname "$0")/.." && pwd)
pidfile=${TMPDIR:-/tmp}/hw1-load.pids

echo "── uptime"
uptime
echo "── top -l 2 -s 3 -n 8 -o cpu  (второй замер)"
top -l 2 -s 3 -n 8 -o cpu -stats pid,ppid,command,cpu,threads,state,time |
    awk '/^Processes:/ { n++ } n == 2 && !/^(SharedLibs|MemRegions|VM|Networks|Disks):/'
echo "── build/cpustat 2  (загрузка по ядрам за 2 с)"
"$root/build/cpustat" 2
if [ -s "$pidfile" ]; then
    pids=$(tr -s ' \n' ',,' < "$pidfile" | sed 's/,$//')
    echo "── ps: процессы из load.sh (всего $(ps -o pid= -p "$pids" | wc -l | tr -d ' '), первые 5)"
    ps -c -o pid,ppid,stat,nice,pri,%cpu,utime,stime,comm -p "$pids" | head -6
fi
