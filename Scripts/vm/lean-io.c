/* Read-only counters for the owned guest helper; never a host workload. */
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char **argv) {
    int vm = 0;
    size_t length = sizeof(vm);
    if (argc != 2 || sysctlbyname("kern.hv_vmm_present", &vm, &length, NULL, 0) || vm != 1)
        return 2;
    char *end = NULL;
    long parsed = strtol(argv[1], &end, 10);
    if (!end || *end || parsed <= 0 || parsed > INT32_MAX) return 2;
    pid_t pid = (pid_t)parsed;
    struct proc_bsdinfo process;
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &process, sizeof(process)) != sizeof(process)
        || process.pbi_uid != getuid() || proc_pidpath(pid, path, sizeof(path)) <= 0)
        return 3;
    const char *name = strrchr(path, '/');
    if (!name || strcmp(name + 1, "macarchy-focus-ring")) return 3;
    struct rusage_info_v4 usage = {0};
    struct timespec sampled;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage)
        || clock_gettime(CLOCK_MONOTONIC, &sampled)) return 3;
    printf("{\"pid\":%d,\"start\":%llu,\"logical_writes\":%llu,"
           "\"disk_bytes_written\":%llu,\"sampled\":%.9f}\n", pid,
           (unsigned long long)usage.ri_proc_start_abstime,
           (unsigned long long)usage.ri_logical_writes,
           (unsigned long long)usage.ri_diskio_byteswritten,
           (double)sampled.tv_sec + (double)sampled.tv_nsec / 1e9);
    return 0;
}
