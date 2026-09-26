// iowait — процесс, который почти все время ждет диск.
// В цикле пишет 4 КиБ и вызывает fcntl(F_FULLFSYNC): ядро просит накопитель сбросить кэш
// и усыпляет поток до конца операции. В ps процесс в состоянии U, в top - stuck.
// В macOS (как в классическом UNIX) такое ожидание НЕ входит в LA, в Linux (состояние D) - входит.
// Запуск: iowait [файл, по умолчанию iowait.tmp] [секунд, по умолчанию 60]
#include <fcntl.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>

int main(int argc, char *argv[])
{
    const char *path = argc > 1 ? argv[1] : "iowait.tmp";
    int secs = argc > 2 ? std::atoi(argv[2]) : 60;

    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        std::perror(path);
        return 1;
    }
    char buf[4096];
    std::memset(buf, 'x', sizeof(buf));

    auto end = std::chrono::steady_clock::now() + std::chrono::seconds(secs);
    long ops = 0;
    for (; std::chrono::steady_clock::now() < end; ops++) {
        if (pwrite(fd, buf, sizeof(buf), 0) != ssize_t(sizeof(buf)) || fcntl(fd, F_FULLFSYNC) < 0) {
            std::perror(path);
            return 1;
        }
    }
    close(fd);
    unlink(path);
    std::printf("iowait[%d]: %ld F_FULLFSYNC в секунду\n", getpid(), ops / (secs > 0 ? secs : 1));
}
