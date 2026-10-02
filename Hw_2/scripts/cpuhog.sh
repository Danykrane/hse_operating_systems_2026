#!/bin/bash
# cpuhog.sh [N=1] [СЕКУНД=60] - N процессов, каждый крутит пустой цикл bash: чистый счет в режиме
# пользователя, как bc в ДЗ 1, только без ввода. Через СЕКУНД (или по Ctrl+C) все завершаются.
n=${1:-1}
secs=${2:-60}

trap 'kill $(jobs -p) 2> /dev/null; exit' INT TERM
for ((i = 0; i < n; i++)); do
    while :; do :; done &
done
sleep "$secs"
kill $(jobs -p) 2> /dev/null
