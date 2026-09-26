// cpustat — загрузка каждого ядра CPU в macOS (аналог mpstat -P ALL в Linux).
// Берет тики USER / SYSTEM / IDLE / NICE из host_processor_info(PROCESSOR_CPU_LOAD_INFO):
// из этих же счетчиков top считает строку «CPU usage».
// Запуск: cpustat [интервал в секундах, по умолчанию 2]
#include <mach/mach.h>
#include <sys/sysctl.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <vector>

using Ticks = std::vector<processor_cpu_load_info_data_t>;

static Ticks sample()
{
    natural_t ncpu = 0;
    processor_info_array_t info;
    mach_msg_type_number_t count;
    if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &ncpu, &info, &count) != KERN_SUCCESS) {
        std::perror("host_processor_info");
        std::exit(1);
    }
    auto *p = reinterpret_cast<processor_cpu_load_info_t>(info);
    Ticks t(p, p + ncpu);
    vm_deallocate(mach_task_self(), vm_address_t(info), count * sizeof(integer_t));
    return t;
}

static void row(const std::string &cpu, const char *core, const double d[CPU_STATE_MAX])
{
    double sum = d[CPU_STATE_USER] + d[CPU_STATE_NICE] + d[CPU_STATE_SYSTEM] + d[CPU_STATE_IDLE];
    if (sum == 0)
        sum = 1;
    double busy = 100 * (sum - d[CPU_STATE_IDLE]) / sum;
    std::string bar(20, '.');
    for (int i = 0; i < int(busy / 5 + 0.5); i++)
        bar[i] = '#';
    std::printf("%4s  %-4s %6.1f %6.1f %6.1f %6.1f   [%s]\n", cpu.c_str(), core,
                100 * d[CPU_STATE_USER] / sum, 100 * d[CPU_STATE_NICE] / sum,
                100 * d[CPU_STATE_SYSTEM] / sum, 100 * d[CPU_STATE_IDLE] / sum, bar.c_str());
}

int main(int argc, char *argv[])
{
    double interval = argc > 1 ? std::atof(argv[1]) : 2.0;

    // Число E-ядер. На Apple Silicon они идут первыми: на M1 Pro это CPU 0-1 (см. ioreg, cluster-type).
    int ecores = 0;
    size_t len = sizeof(ecores);
    sysctlbyname("hw.perflevel1.logicalcpu", &ecores, &len, nullptr, 0);

    Ticks a = sample();
    std::this_thread::sleep_for(std::chrono::duration<double>(interval));
    Ticks b = sample();

    std::printf(" CPU  core  %%user  %%nice   %%sys  %%idle   занятость\n");
    double total[CPU_STATE_MAX] = {};
    for (size_t i = 0; i < b.size(); i++) {
        double d[CPU_STATE_MAX];
        for (int s = 0; s < CPU_STATE_MAX; s++) {
            d[s] = double(b[i].cpu_ticks[s] - a[i].cpu_ticks[s]); // unsigned: переполнение не страшно
            total[s] += d[s];
        }
        row(std::to_string(i), int(i) < ecores ? "E" : "P", d);
    }
    row("all", "", total);

    double la[3];
    if (getloadavg(la, 3) == 3)
        std::printf("load average: %.2f %.2f %.2f\n", la[0], la[1], la[2]);
}
