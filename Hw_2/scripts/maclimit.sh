#!/bin/bash
# maclimit.sh - ограничить CPU и память процесса в macOS. В ядре XNU нет cgroups, поэтому ограничивает
# сам скрипт: каждые 100 мс смотрит через ps на дерево процессов (процесс и все его потомки) и
#   CPU    - как cpu.max в cgroups: квота CPU-времени на период 100 мс; дерево ее превысило -
#            SIGSTOP, пока не «отработает» долг, потом SIGCONT;
#   память - свой OOM killer: RSS дерева больше лимита - SIGKILL самому большому процессу.
#
#   maclimit.sh [-c CPU%] [-m MEM] [-b] [-i SEC] [--] COMMAND [ARGS...]
#   maclimit.sh [-c CPU%] [-m MEM] [-i SEC] -p PID
#
#   -c CPU%  CPU в процентах одного ядра на все дерево: 50 - половина ядра, 200 - два ядра
#   -m MEM   лимит памяти в RAM (сумма RSS дерева): 512K, 100M, 1G
#   -b       запустить с QoS background (taskpolicy -c background): только E-ядра, низший приоритет
#   -i SEC   печатать потребление раз в SEC секунд, 0 - не печатать. По умолчанию 1
#   -p PID   ограничить уже работающий процесс и его потомков; Ctrl+C - снять ограничение
#
# Когда процесс завершился, печатает итог: код выхода, CPU, пик памяти, сколько было OOM kill.
# Запущенную им команду завершает целиком: по Ctrl+C и после ее выхода - и оставшихся потомков.
# Написан под /bin/bash 3.2 и BSD-утилиты macOS. Свои процессы ограничивает без sudo.
set -u

die() { echo "maclimit: $*" >&2; exit 2; }
usage() { sed -n '8,9s/^#   //p' "$0" >&2; echo "подробнее: head -19 $0" >&2; exit 2; }
isnum() { case $1 in '' | *[!0-9]*) return 1 ;; esac; }
kb() {   # 100M -> 102400: ps показывает RSS в КБ
    local n=${1%[kKmMgG]}
    isnum "$n" || die "неверный размер «$1»: нужно 512K, 100M или 1G"
    case $1 in
        *[kK]) echo $((10#$n)) ;;
        *[mM]) echo $((10#$n * 1024)) ;;
        *[gG]) echo $((10#$n * 1048576)) ;;
        *) echo $((10#$n / 1024)) ;;
    esac
}
mib() { LC_ALL=C awk -v k="$1" 'BEGIN { printf "%.1fM", k / 1024 }'; }

cpu='' mem='' bg='' interval=1 pid=''
while getopts c:m:bi:p:h opt; do
    case $opt in
        c) cpu=$OPTARG ;;
        m) mem=$OPTARG ;;
        b) bg=1 ;;
        i) interval=$OPTARG ;;
        p) pid=$OPTARG ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

[ -n "$pid" ] || [ $# -gt 0 ] || usage
[ -z "$pid" ] || [ $# -eq 0 ] || die "нужно что-то одно: -p PID или команда"
[ -n "$cpu$mem" ] || die "не задан ни один лимит: -c и/или -m"
[ -z "$cpu" ] || { isnum "$cpu" && [ "$cpu" -gt 0 ]; } || die "-c: нужно целое число процентов, например 50"
isnum "$interval" || die "-i: нужно целое число секунд"
[ -z "$pid" ] || [ -z "$bg" ] || die "-b только для новой команды"
[ -z "$pid" ] || { isnum "$pid" && kill -0 "$pid" 2> /dev/null; } || die "нет процесса $pid или нет прав на него (sudo)"
if [ -n "$mem" ]; then mem=$(kb "$mem") || exit 2; fi

# Снимок дерева процессов от $root одной строкой:
#   жив_ли_root  RSS_КБ  CPU_мс  PID_самого_большого  его_RSS_КБ  PID PID ...
# CPU - сумма user + sys всех процессов дерева. Формат time в BSD ps - M:SS.hh, в GNU - [DD-]HH:MM:SS.
snapshot() {
    LC_ALL=C ps -A -o pid=,ppid=,rss=,time=,stat= | LC_ALL=C awk -v root="$root" '
        function ms(t,   a, n, d) {
            d = 0
            if (index(t, "-")) { split(t, a, "-"); d = a[1]; t = a[2] }
            n = split(t, a, ":")
            return int(((d * 24 + (n == 3 ? a[1] : 0)) * 3600 + a[n - 1] * 60 + a[n]) * 1000 + 0.5)
        }
        { kids[$2] = kids[$2] " " $1; rss[$1] = $3; cpu[$1] = ms($4); st[$1] = $5 }
        END {
            if (!(root in rss) || st[root] ~ /^Z/) { print 0; exit }
            q = root
            while (q != "") {
                n = split(q, a, " "); q = ""
                for (i = 1; i <= n; i++) {
                    p = a[i]; list = list " " p; r += rss[p]; c += cpu[p]
                    if (rss[p] > br) { br = rss[p]; bp = p }
                    if (p in kids) q = q kids[p]
                }
            }
            print 1, r + 0, c + 0, bp + 0, br + 0, list
        }'
}

list=''
cleanup() {   # что бы ни случилось - не оставить процессы остановленными
    [ -z "$list" ] || kill -CONT $list 2> /dev/null
}
trap cleanup EXIT
stop=''
trap 'stop=1' INT TERM

# ── запуск
if [ -n "$pid" ]; then
    root=$pid
else
    exec 3<&0   # фоновой команде bash подставил бы stdin из /dev/null, отдаем ей наш stdin
    if [ -n "$bg" ]; then
        taskpolicy -c background "$@" <&3 3<&- &
    else
        "$@" <&3 3<&- &
    fi
    root=$!
fi
if [ -n "$pid" ]; then name=$(ps -o comm= -p "$pid" 2> /dev/null); else name=$1; fi
name=${name##*/}
cpu_txt='без лимита' mem_txt='без лимита'
[ -z "$cpu" ] || cpu_txt="до $cpu% одного ядра"
[ -z "$mem" ] || mem_txt="до $(mib "$mem")"
echo "maclimit: PID $root ($name): CPU $cpu_txt, RSS $mem_txt${bg:+, QoS background (только E-ядра)}" >&2

# ── основной цикл: один оборот - один период 100 мс
tick=0.1 per=$((interval * 10))
balance=${cpu:-0}         # остаток квоты CPU, мс; меньше 0 - дерево стоит
stopped=0 ticks=0 throttled=0 total=0 peak=0 oom=0 victim='' gone=''
iused=0 ithr=0            # за текущий интервал печати
read -r alive r last _ <<< "$(snapshot)"
[ "${alive:-0}" = 1 ] || last=0
while [ -z "$stop" ]; do
    LC_ALL=C sleep $tick &   # пока идет период, считаем и раздаем сигналы
    s=$!
    snap=$(snapshot)
    [ -z "$stop" ] || { wait $s 2> /dev/null; break; }   # Ctrl+C мог оборвать ps - такому снимку не верим
    read -r alive r c bp br pids <<< "$snap"
    [ "${alive:-0}" = 1 ] || { gone=1; wait $s 2> /dev/null; break; }
    list=$pids ticks=$((ticks + 1))

    used=$((c - last))        # CPU за прошлый период; процесс вышел - сумма уменьшилась
    [ $used -ge 0 ] || used=0
    last=$c total=$((total + used)) iused=$((iused + used))
    if [ -n "$cpu" ]; then
        balance=$((balance + cpu - used))
        [ $balance -le "$cpu" ] || balance=$cpu   # копить квоту больше чем на 1 период нельзя
        if [ "$balance" -lt 0 ]; then
            kill -STOP $list 2> /dev/null   # каждый раз, чтобы остановить и новых потомков
            stopped=1 throttled=$((throttled + 1)) ithr=$((ithr + 1))
        elif [ $stopped = 1 ]; then
            kill -CONT $list 2> /dev/null
            stopped=0
        fi
    fi

    [ "$r" -le "$peak" ] || peak=$r
    if [ -n "$mem" ] && [ "$r" -gt "$mem" ] && [ "$bp" != "$victim" ]; then
        vname=$(ps -o comm= -p "$bp" 2> /dev/null)
        kill -KILL "$bp" 2> /dev/null
        oom=$((oom + 1)) victim=$bp vname=${vname##*/} vrss=$br
        echo "maclimit: OOM: RSS $(mib "$r") > $(mib "$mem"), SIGKILL -> PID $bp ($vname, $(mib "$br"))" >&2
    fi

    if [ $per -gt 0 ] && [ $((ticks % per)) -eq 0 ]; then
        LC_ALL=C awk -v t=$((ticks / 10)) -v u=$iused -v n=$per -v r="$r" -v lim="${mem:-0}" \
            -v th=$ithr -v oom=$oom 'BEGIN {
                printf "[%3d с] CPU %6.1f%%  RSS %8s / %s  стоп %3d/%d  OOM kill %d\n", t, u / n,
                       sprintf("%.1fM", r / 1024), lim ? sprintf("%.1fM", lim / 1024) : "без лимита", th, n, oom }' >&2
        iused=0 ithr=0
    fi
    wait $s 2> /dev/null
done

# ── завершение: $list - последний целый снимок дерева, никого в нем не оставить остановленным
if [ -z "$gone" ]; then   # Ctrl+C: свежий снимок, вдруг появились новые потомки
    read -r alive r c bp br pids <<< "$(snapshot)"
    [ "${alive:-0}" != 1 ] || list="$list $pids"
fi
[ -z "$list" ] || kill -CONT $list 2> /dev/null
rc=''
if [ -z "$pid" ]; then   # команду запускали мы: после Ctrl+C или ее выхода завершаем и ее потомков
    [ -z "$list" ] || kill -TERM $list 2> /dev/null
    wait "$root" 2> /dev/null
    rc=$?
fi

# ── итог
echo "── итог: PID $root ($name)"
if [ -n "$pid" ]; then
    if [ -n "$gone" ]; then echo "процесс завершился"; else echo "ограничение снято, процесс работает дальше"; fi
elif [ -n "$stop" ]; then
    echo "прервано (Ctrl+C), дерево процессов завершено, код $rc"
elif [ "$rc" -eq 0 ]; then
    echo "команда завершилась успешно (код 0)"
elif [ "$rc" -gt 128 ]; then
    echo "команда убита сигналом $((rc - 128)) (SIG$(kill -l $((rc - 128)))), код $rc"
else
    echo "команда завершилась с кодом $rc"
fi
LC_ALL=C awk -v u=$total -v n=$ticks -v lim="$cpu" -v th=$throttled 'BEGIN {
    printf "CPU: %.1f с за %.1f с, в среднем %.1f%% одного ядра", u / 1000, n / 10, n ? u / n : 0
    if (lim) printf " при лимите %d%%, стоял в %d периодах из %d", lim, th, n
    print "" }'
echo "память: пик RSS $(mib "$peak")${mem:+ при лимите $(mib "$mem")}, OOM kill: $oom${victim:+ (последний: PID $victim, $vname, $(mib "${vrss:-0}"))}"
[ -z "$rc" ] || exit "$rc"
