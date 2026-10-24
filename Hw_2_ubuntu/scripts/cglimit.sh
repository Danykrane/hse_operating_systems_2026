#!/bin/bash
# cglimit.sh - ограничить CPU и память процесса через cgroups v2 и пакет cgroup-tools.
# Создает группу (cgcreate), ставит лимиты (cgset), запускает в ней команду (cgexec) или переносит
# туда уже работающий процесс с потомками (cgclassify). Раз в секунду печатает потребление, в конце -
# итог: код выхода, OOM kill, строки ядра из dmesg. Группу удаляет всегда (cgdelete), даже по Ctrl+C.
#
#   sudo ./cglimit.sh [-c CPU%] [-m MEM] [-s SWAP] [-n NAME] [-i SEC] -- COMMAND [ARGS...]
#   sudo ./cglimit.sh [-c CPU%] [-m MEM] [-s SWAP] [-n NAME] [-i SEC] -p PID
#
#   -c CPU%  CPU в процентах одного ядра на всю группу: 50 - половина ядра, 150 - полтора   cpu.max
#   -m MEM   лимит RAM: 200M, 1G                                                            memory.max
#   -s SWAP  лимит swap: 0 - swap запрещен, max - без лимита (по умолчанию не меняется)     memory.swap.max
#   -n NAME  имя группы, по умолчанию cglimit_<PID скрипта>
#   -i SEC   печатать потребление раз в SEC секунд, по умолчанию 1
#   -p PID   ограничить уже работающий процесс и его потомков; Ctrl+C - вернуть их в прежнюю группу
#
# При нехватке памяти ядро убивает всю группу сразу (memory.oom.group=1), поэтому команда
# завершается с кодом 137 = 128 + 9 (SIGKILL). Скрипт выходит с кодом команды.
set -u

die() { echo "cglimit: $*" >&2; exit 2; }
usage() { sed -n '7,8s/^#   //p' "$0" >&2; echo "подробнее: head -18 $0" >&2; exit 2; }
isnum() { case $1 in '' | *[!0-9]*) return 1 ;; esac; }
mb() { if isnum "$1"; then local t=$(($1 * 10 / 1048576)); echo "$((t / 10)).$((t % 10))M"; else echo "$1"; fi; }

cpu='' mem='' swap='' name="cglimit_$$" interval=1 pid=''
while getopts c:m:s:n:i:p:h opt; do
    case $opt in
        c) cpu=$OPTARG ;;
        m) mem=$OPTARG ;;
        s) swap=$OPTARG ;;
        n) name=$OPTARG ;;
        i) interval=$OPTARG ;;
        p) pid=$OPTARG ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

[ -n "$pid" ] || [ $# -gt 0 ] || usage
[ -z "$pid" ] || [ $# -eq 0 ] || die "нужно что-то одно: -p PID или команда"
[ -n "$cpu$mem$swap" ] || die "не задан ни один лимит: -c, -m или -s"
[ -z "$cpu" ] || { isnum "$cpu" && [ "$cpu" -gt 0 ]; } || die "-c: нужно целое число процентов, например 50"
{ isnum "$interval" && [ "$interval" -gt 0 ]; } || die "-i: нужно целое число секунд"
[ "$(id -u)" -eq 0 ] || die "нужен root: sudo $0 ..."
for t in cgcreate cgset cgget cgexec cgclassify cgdelete; do
    command -v $t > /dev/null || die "нет $t: поставьте пакет cgroup-tools (sudo apt install cgroup-tools)"
done
[ -f /sys/fs/cgroup/cgroup.controllers ] || die "нужен cgroup v2 (Ubuntu 21.10 и новее), здесь cgroup v1"
[ -z "$pid" ] || { isnum "$pid" && kill -0 "$pid" 2> /dev/null; } || die "нет процесса $pid"
cg=/sys/fs/cgroup/$name
[ ! -e "$cg" ] || die "группа $name уже есть, удалить: sudo cgdelete -g cpu,memory:$name"

# 1. Группа и лимиты. cpu.max = "квота период" в мкс: 50% одного ядра = 50 мс CPU на каждые 100 мс.
cgcreate -g cpu,memory:"$name" || die "cgcreate не смог создать группу $name"
cleanup() {   # на любом выходе: команду - добить, процесс по -p - вернуть назад; группу удалить
    if [ -n "$old" ]; then
        procs=$(cat "$cg/cgroup.procs")
        [ -z "$procs" ] || cgclassify -g cpu,memory:"$old" $procs
    elif grep -q 'populated 1' "$cg/cgroup.events"; then
        echo 1 > "$cg/cgroup.kill"   # SIGKILL всем, кто остался в группе
        for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q 'populated 0' "$cg/cgroup.events" && break; sleep 0.1; done
    fi
    cgdelete -g cpu,memory:"$name" && echo "cglimit: группа $name удалена (cgdelete)"
}
old=''
trap cleanup EXIT
set_() { cgset -r "$1=$2" "$name" || die "cgset не принял $1=$2"; }
[ -z "$cpu" ] || set_ cpu.max "$((cpu * 1000)) 100000"
[ -z "$mem" ] || set_ memory.max "$mem"
[ -z "$swap" ] || set_ memory.swap.max "$swap"
set_ memory.oom.group 1
echo "cglimit: группа $cg (cgget): $(cgget -n -r cpu.max -r memory.max -r memory.swap.max \
    -r memory.oom.group "$name" | awk -F': ' 'NF { printf "%s%s=%s", sep, $1, $2; sep = ", " }')"
read -r mem_max < "$cg/memory.max"
read -r swap_max < "$cg/memory.swap.max"

# 2. Статистика группы из ее файлов в /sys/fs/cgroup
sample() {   # -> usage (мкс CPU), periods, throttled, cur, swp, oom
    while read -r k v; do
        case $k in usage_usec) usage=$v ;; nr_periods) periods=$v ;; nr_throttled) throttled=$v ;; esac
    done < "$cg/cpu.stat"
    read -r cur < "$cg/memory.current"
    read -r swp < "$cg/memory.swap.current"
    oom=$(awk '$1 == "oom_kill" { print $2 }' "$cg/memory.events")
    now=${EPOCHREALTIME/./}
}
monitor() {   # строка раз в $interval с, пока в группе есть процессы и не нажат Ctrl+C
    local u0 p0 t0 n0 cpu10 thr
    sample
    while [ -z "$stop" ]; do
        u0=$usage p0=$periods t0=$throttled n0=$now
        sleep "$interval"
        [ -z "$stop" ] && grep -q 'populated 1' "$cg/cgroup.events" || break
        sample
        cpu10=$(((usage - u0) * 1000 / (now - n0)))
        thr='-'
        [ "$periods" -eq "$p0" ] || thr="$((throttled - t0))/$((periods - p0))"
        printf '[%3d с] CPU %5d.%d%%  RAM %7s / %-7s  swap %7s / %-7s  троттлинг %-7s  OOM kill %s\n' \
            "$SECONDS" $((cpu10 / 10)) $((cpu10 % 10)) "$(mb "$cur")" "$(mb "$mem_max")" \
            "$(mb "$swp")" "$(mb "$swap_max")" "$thr" "$oom"
    done
}

# 3. Запуск: новая команда через cgexec или перенос процесса по PID через cgclassify
dmesg_lines=$(dmesg | wc -l)
SECONDS=0
start=${EPOCHREALTIME/./}
stop=''
trap 'stop=1' INT
if [ -n "$pid" ]; then
    tree() { echo "$1"; local c; for c in $(pgrep -P "$1"); do tree "$c"; done; }
    pids=$(tree "$pid")
    old=$(cut -d: -f3 "/proc/$pid/cgroup")
    cgclassify -g cpu,memory:"$name" $pids || die "cgclassify не смог перенести $pid"
    echo "cglimit: cgclassify -g cpu,memory:$name" $pids "(были в $old, Ctrl+C - вернуть назад)"
    monitor
    rc=0
else
    echo "cglimit: cgexec -g cpu,memory:$name $*"
    monitor &
    mon=$!
    cgexec -g cpu,memory:"$name" "$@"
    rc=$?
    kill "$mon" 2> /dev/null
fi

# 4. Итог
sample
elapsed=$((now - start))
cpu10=$((usage * 1000 / (elapsed > 0 ? elapsed : 1)))
printf 'cglimit: итог за %d.%02d с\n' $((elapsed / 1000000)) $((elapsed / 10000 % 100))
if [ -n "$old" ]; then
    if [ -n "$stop" ]; then echo "  ограничение снято, процессы вернутся в $old"; else echo "  процесс $pid завершился"; fi
elif [ "$rc" -gt 128 ]; then
    echo "  код выхода $rc: команда убита сигналом $((rc - 128)) (SIG$(kill -l $((rc - 128))))"
else
    echo "  код выхода $rc"
fi
line="  CPU     в среднем $((cpu10 / 10)).$((cpu10 % 10))% одного ядра"
[ -z "$cpu" ] || line+=" при лимите $cpu%, троттлинг в $throttled из $periods периодов по 100 мс"
echo "$line"
peak() { if [ -r "$cg/$1" ]; then mb "$(< "$cg/$1")"; else echo '?'; fi; }   # memory.peak - с ядра 5.19
echo "  память  пик RAM $(peak memory.peak) из $(mb "$mem_max"), пик swap $(peak memory.swap.peak) из $(mb "$swap_max")"
echo "  memory.events:" $(< "$cg/memory.events")
if [ "${oom:-0}" -gt 0 ]; then
    echo "  OOM kill в группе: $oom. Ядро (dmesg, главное из строк):"
    dmesg | tail -n +$((dmesg_lines + 1)) | grep -E 'oom-kill:|Killed process|memory.oom.group' | sed -E '
        s/(constraint=[A-Z_]+),.*(oom_memcg=[^,]+),.*(task=[^,]+,pid=[0-9]+).*/\1,\2,\3/
        s/ total-vm:.*(anon-rss:[0-9]+kB).*/ \1/; s/^/    /'
fi
exit "$rc"
