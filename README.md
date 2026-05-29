# linsys.c3l

A simple Linux system and process introspection library for C3.

`linsys.c3l` provides APIs for querying system state, inspecting processes and monitoring resources.


# Features

- Process inspection and management
- CPU and system statistics
- Memory and swap information
- Disk usage and IO statistics
- Network interfaces and connections
- Hardware sensors and battery information

# Error Handling

Functions returning structs will often return partially populated values instead of failing entirely when individual fields cannot be retrieved due to:
- permission restrictions
- missing kernel information
- unsupported interfaces
- process state changes

Example:

```c
ProcessInfo pi = get_info(tmem, pid) ?? {};
```

Some fields inside `ProcessInfo` may be just empty if specific information could not be read, while the overall call still succeeds.

However, functions will still fail normally in cases where the primary operation itself cannot be completed, like:
- process does not exist
- `/proc/<pid>` cannot be accessed
- required files are missing

Other APIs like example - `cpu_affinity_set` will fail directly and should be handled explicitly by the caller.

# Installation

Using `c3l`:

```bash
c3l fetch https://github.com/vamsi200/linsys.c3l
```

You can get `c3l` from:

https://github.com/konimarti/c3l

# Few Examples

### Process Information

```c
module sys;

import std::io;

fn int main(String[] args) {
    ProcessInfo pi = get_info(tmem, 1) ?? {};
    io::printn(pi);

    return 0;
}
```
Output:

```text
{ process: { pid: 1, ppid: 0, name: systemd, state: SLEEPING }, exe_path: , cmdline: /usr/lib/systemd/systemd --switched-root --system --deserialize=50, uid: 0, gid: 0, threads: 1, vm_size: 23380, vm_rss: 14468 }
```

### Memory Statistics

```c
module sys;

import std::io;

fn int main(String[] args) {
    VirtualMemory mem = virtual_memory() ?? {};
    io::printn(mem);

    return 0;
}
```
Output:

```text
{ total: 16060632, available: 8165128, used: 7895504, free: 3811580, percent: 49.160606, active: 6422480, inactive: 2956032, buffers: 308116, cached: 5989504, shared: 1612580, slab: 307080, reclaimable: 148860, swap_cached: 0, dirty: 4216, writeback: 0, mapped: 1177808, page_tables: 53276, committed: 46585116, commit_limit: 16060520 }
```


### Disk Usage

```c
module sys;

import std::io;

fn int main(String[] args) {
    DiskUsage usage = disk_usage("/") ?? {};
    io::printn(usage);

    return 0;
}
```

Output:
```text
{ total: 501859205120, used: 448485535744, free: 53373669376, percent: 89.364812 }
```

# API Reference (could change)

<details>
<summary><code>process</code></summary>

```c
fn ProcessInfo? get_info(Allocator allocator, int pid)
fn Process? get_proc(Allocator allocator, int pid)

fn String? read_cmdline(Allocator allocator, int pid)
fn String? read_exe(Allocator allocator, int pid)

fn int[]? list_pids(Allocator allocator)
fn bool exists(int pid)

fn String? cwd(Allocator allocator, int pid)

fn EnvVar[]? environ(Allocator allocator, int pid)

fn String[]? fd_paths(Allocator allocator, int pid)
fn int[]? fds(Allocator allocator, int pid)

fn MemoryMap[]? maps(Allocator allocator, int pid)

fn OpenFile[]? open_files(Allocator allocator, int pid)

fn Connection[]? connections(Allocator allocator, int pid)
macro ulong boot_time()
fn double? create_time(int pid)
macro ulong clktck()

fn CpuTimes? cpu_times(int pid)
fn CpuTimes? cpu_times_threads(int pid, int tid)
fn CpuSnapshot? cpu_snapshot(int pid)
fn double? cpu_percent_from(CpuSnapshot first, int pid)
fn double? cpu_percent(int pid, double interval)

fn double? memory_percent(int pid)

fn IoCounters? io_counters(int pid)

fn bool send_signal(int pid, Signal signal)

fn bool suspend(int pid)
fn bool resume(int pid)
fn bool kill(int pid)
fn bool terminate(int pid)
fn bool interrupt(int pid)

fn int[]? children(Allocator allocator, int pid, bool recursive)
fn int? parent(int pid)

fn int? nice_get(int pid)
fn void? nice_set(int pid, int value)

fn int[]? cpu_affinity_get(Allocator allocator, int pid)
fn void? cpu_affinity_set(int pid, int[] cpus)

fn RLimitEntry[]? rlimits_get(Allocator allocator, int pid)

fn ThreadInfo[]? threads(Allocator allocator, int pid)
```

</details>


<details>
<summary><code>system</code></summary>

```c
fn SystemCpuTimes? sys_cpu_times()

fn SystemCpuTimes[]? cpu_times_percpu(Allocator allocator)

fn SystemCpuSnapshot? cpu_snapshot()
fn SystemCpuSnapshot[]? cpu_snapshot_percpu(Allocator allocator)

fn double sys_cpu_percent(CpuSnapshot old, CpuSnapshot new)

fn double[]? sys_cpu_percent_percpu(
    Allocator allocator,
    SystemCpuSnapshot[] old,
    SystemCpuSnapshot[] new
)

fn CpuCount? cpu_count()

fn CpuFreq? cpu_freq()
fn CpuFreq[]? cpu_freq_percpu(Allocator allocator)

fn CpuStats? cpu_stats()

fn LoadAvg? loadavg()

fn CpuInfo[]? cpu_info(Allocator allocator)

fn CpuTemp[]? cpu_temps(Allocator allocator)

fn CpuUsage cpu_usage(SystemCpuTimes old, SystemCpuTimes new)
fn double? uptime()
fn String? hostname(Allocator allocator)
fn String? kernel_version(Allocator allocator)
fn String? os_release(Allocator allocator)
```

</details>


<details>
<summary><code>memory</code></summary>

```c
fn VirtualMemory? virtual_memory()

fn SwapMemory? swap_memory()
```

</details>

<details>
<summary><code>disk</code></summary>

```c
fn DiskPartition[]? disk_partitions(Allocator allocator)

fn DiskUsage? disk_usage(String path)

fn DiskIoCounters[]? disk_io_counters(Allocator allocator)
fn DiskIoCounters? disk_io_counters_perdisk(Allocator allocator, String device, DiskContext* ctx)
```

</details>

<details>
<summary><code>network</code></summary>

```c
fn NetIoCounters[]? net_io_counters(Allocator allocator)

fn Connection[]? net_connections(Allocator allocator)

fn NetIfAddr[]? net_if_addrs(Allocator allocator)

fn NetIfStats[]? net_if_stats(Allocator allocator)
```

</details>

<details>
<summary><code>sensors</code></summary>

```c
fn SensorTemperature[]? sensor_temperatures(Allocator allocator)

fn SensorFan[]? sensor_fans(Allocator allocator)

fn SensorBattery[]? sensor_battery(Allocator allocator)
```

</details>
