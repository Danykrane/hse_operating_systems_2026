// threads — один процесс с N занятыми потоками.
// Показывает, что LA считает потоки, а не процессы: LA растет примерно на N,
// а у процесса в top %CPU около N * 100%.
// Запуск: threads [N, по умолчанию 4] [секунд, по умолчанию 60]
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <thread>
#include <vector>

int main(int argc, char *argv[])
{
    int n = argc > 1 ? std::atoi(argv[1]) : 4;
    int secs = argc > 2 ? std::atoi(argv[2]) : 60;

    std::atomic<bool> stop{false};
    std::vector<std::thread> pool;
    for (int i = 0; i < n; i++)
        pool.emplace_back([&stop] {
            for (volatile unsigned long x = 0; !stop.load(std::memory_order_relaxed); x++) {
            }
        });

    std::this_thread::sleep_for(std::chrono::seconds(secs)); // главный поток спит
    stop = true;
    for (auto &t : pool)
        t.join();
}
