module sys;
import std::core::mem;

fn void test_virtual_memory_succeeds() @test {
    @pool() {
        VirtualMemory? vm = virtual_memory();
        if (catch vm) {
            unreachable("/proc/meminfo should always be readable");
        }
        assert (vm.total > 0 , "total memory must be nonzero");
        assert (vm.used <= vm.total , "used cannot exceed total");
        assert (vm.available <= vm.total , "available cannot exceed total");
        assert (vm.percent >= 0.0 && vm.percent <= 100.0 , "percent out of range");
    };
}

fn void test_swap_memory_valid_range() @test {
    @pool() {
        SwapMemory? sm = swap_memory();
        if (catch sm) {
            unreachable("/proc/meminfo should always be readable");
        }
        assert (sm.used <= sm.total , "swap used cannot exceed total");
        if (sm.total > 0) {
            assert (sm.percent >= 0.0 && sm.percent <= 100.0 , "swap percent out of range");
            assert (sm.free <= sm.total , "swap free cannot exceed total");
        }
    };
}

fn void test_memory_poller_consistent() @test {
    @pool() {
        MemoryPoller? mp = memory_poller_new(tmem);
        if (catch mp) {
            unreachable("memory poller should always initialize");
        }
        defer mp.close();
        VirtualMemory? first  = mp.poll_virtual();
        VirtualMemory? second = mp.poll_virtual();
        if (catch first) unreachable("first poll should succeed");
        if (catch second) unreachable("second poll should succeed");

        assert (first.total == second.total , "total memory changed between polls");
    };
}

fn void test_sys_cpu_times_valid() @test {
    @pool() {
        SystemCpuTimes? times = sys_cpu_times();
        if (catch times) {
            unreachable("/proc/stat should always be readable");
        }
        assert (times.user >= 0.0 , "user time must be non-negative");
        assert (times.system >= 0.0 , "system time must be non-negative");
        assert (times.idle >= 0.0 , "idle time must be non-negative");
    };
}

fn void test_loadavg_valid_range() @test {
    @pool() {
        LoadAvg? la = loadavg();
        if (catch la) {
            unreachable("/proc/loadavg should always be readable");
        }
        assert (la.one >= 0.0 , "1min load must be non-negative");
        assert (la.five >= 0.0 , "5min load must be non-negative");
        assert (la.fifteen >= 0.0 , "15min load must be non-negative");
    };
}

fn void test_cpu_count_valid() @test {
    @pool() {
        CpuCount? count = cpu_count();
        if (catch count) {
            unreachable("cpu_count should always succeed");
        }
        assert (count.logical > 0 , "must have at least one logical cpu");
        assert (count.physical > 0 , "must have at least one physical cpu");
        assert (count.logical >= count.physical , "logical must be >= physical");
    };
}

fn void test_uptime_positive() @test {
    @pool() {
        double? up = uptime();
        if (catch up) {
            unreachable("/proc/uptime should always be readable");
        }
        assert (up > 0.0 , "uptime must be positive");
    };
}

fn void test_hostname_not_empty() @test {
    @pool() {
        String? h = hostname(tmem);
        if (catch h) return;
        assert (h.len > 0 , "hostname must not be empty");
    };
}

fn void test_kernel_version_not_empty() @test {
    @pool() {
        String? kv = kernel_version(tmem);
        if (catch kv) return;
        assert (kv.len > 0 , "kernel version must not be empty");
    };
}

fn void test_cpu_snapshot_monotonic() @test {
    @pool() {
        SystemCpuSnapshot? s1 = sys_cpu_snapshot();
        SystemCpuSnapshot? s2 = sys_cpu_snapshot();
        if (catch s1) unreachable("sys_cpu_snapshot should always succeed");
        if (catch s2) unreachable("sys_cpu_snapshot should always succeed");

        assert (s2.total >= s1.total , "total cpu time decreased between snapshots");
    };
}

fn void test_cpu_percent_valid_range() @test {
    @pool() {
        SystemCpuSnapshot? s1 = sys_cpu_snapshot();
        SystemCpuSnapshot? s2 = sys_cpu_snapshot();
        if (catch s1) unreachable("snapshot should succeed");
        if (catch s2) unreachable("snapshot should succeed");
        double pct = sys_cpu_percent(s1, s2);
        assert (pct >= 0.0 && pct <= 100.0 , "cpu percent out of range");
    };
}


fn void test_net_io_counters_has_loopback() @test {
    @pool() {
        NetIoCounters[]? counters = net_io_counters(tmem);
        if (catch counters) {
            unreachable("/proc/net/dev should always be readable");
        }
        assert (counters.len > 0 , "expected at least one interface");
        bool found_lo = false;
        foreach (c : counters) {
            assert (c.name.len > 0 , "interface name must not be empty");
            if (c.name == "lo") found_lo = true;
        }
        assert (found_lo , "loopback interface not found");
    };
}

fn void test_net_connections_valid_protocol() @test {
    @pool() {
        Connection[]? conns = net_connections(tmem, { Protocol.TCP });
        if (catch conns) return;
        foreach (c : conns) {
            assert (c.protocol == Protocol.TCP , "protocol field mismatch");
            assert (c.local_addr.len > 0 , "local addr must not be empty");
        }
    };
}

fn void test_net_if_addrs_has_loopback() @test {
    @pool() {
        NetIfAddr[]? addrs = net_if_addrs(tmem);
        if (catch addrs) return;
        bool found_lo = false;
        foreach (a : addrs) {
            assert (a.name.len > 0 , "interface name must not be empty");
            assert (a.address.len > 0 , "address must not be empty");
            if (a.name == "lo") found_lo = true;
        }
        assert (found_lo , "loopback interface not found in if_addrs");
    };
}


fn void test_disk_usage_root_valid() @test {
    @pool() {
        DiskUsage? usage = disk_usage("/");
        if (catch usage) {
            unreachable("disk_usage('/') should always succeed");
        }
        assert (usage.total > 0 , "root total must be nonzero");
        assert (usage.used <= usage.total , "used cannot exceed total");
        assert (usage.free <= usage.total , "free cannot exceed total");
        assert (usage.percent >= 0.0 && usage.percent <= 100.0 , "percent out of range");
    };
}

fn void test_disk_usage_invalid_path_fails() @test {
    @pool() {
        DiskUsage? usage = disk_usage("/nonexistenttest/path/xyz123");
        if (try test = usage) {
            unreachable("expected error for nonexistent path");
        }
    };
}

fn void test_disk_partitions_not_empty() @test {
    @pool() {
        DiskPartition[]? parts = disk_partitions(tmem);
        if (catch parts) {
            unreachable("/proc/mounts should always be readable");
        }
        assert (parts.len > 0 , "expected at least one partition");
        foreach (p : parts) {
            assert (p.device.len > 0 , "device must not be empty");
            assert (p.mountpoint.len > 0 , "mountpoint must not be empty");
        }
    };
}

fn void test_disk_io_counters_valid() @test {
    @pool() {
        DiskContext ctx;
        ctx.init(tmem);
        defer ctx.free();
        DiskIoCounters[]? counters = disk_io_counters(tmem, &ctx);
        if (catch counters) {
            unreachable("/proc/diskstats should always be readable");
        }
        foreach (d : counters) {
            assert (d.name.len > 0 , "disk name must not be empty");
        }
    };
}

fn void test_disk_io_counters_perdisk_invalid_fails() @test {
    @pool() {
        DiskContext ctx;
        ctx.init(tmem);
        defer ctx.free();
        DiskIoCounters? result = disk_io_counters_perdisk(tmem, "nonexistenttest0", &ctx);
        if (try test = result) {
            unreachable("expected NOT_FOUND for nonexistent device");
        }
    };
}


fn void test_sensor_temperatures_sane_values() @test {
    @pool() {
        SensorTemperature[]? temps = sensor_temperatures(tmem);
        if (catch temps) {
            unreachable("sensor_temperatures should return empty not error when no sensors");
        }
        foreach (t : temps) {
            assert (t.name.len > 0 , "sensor name must not be empty");
            assert (t.current > -50.0 && t.current < 150.0 , "temperature out of sane range");
        }
    };
}

fn void test_sensor_fans_sane_values() @test {
    @pool() {
        SensorFan[]? fans = sensor_fans(tmem);
        if (catch fans) {
            unreachable("sensor_fans should return empty not error when no fans");
        }
        foreach (f : fans) {
            assert (f.name.len > 0 , "fan name must not be empty");
            assert (f.current >= 0 , "fan speed must be non-negative");
        }
    };
}

fn void test_sensor_battery_graceful() @test {
    @pool() {
        SensorBattery[]? batteries = sensor_battery(tmem);
        if (catch batteries) return;
        foreach (b : batteries) {
            assert (b.name.len > 0 , "battery name must not be empty");
            assert (b.percent >= 0.0 && b.percent <= 100.0 , "battery percent out of range");
        }
    };
}

fn void test_list_pids_not_empty() @test {
    @pool() {
        int[]? pids = list_pids(tmem);
        if (catch pids) {
            unreachable("/proc listing should always succeed");
        }
        assert (pids.len > 0 , "expected at least one pid");

        bool found_init = false;
        foreach (pid : pids) {
            assert (pid > 0 , "all pids must be positive");
            if (pid == 1) found_init = true;
        }
        assert (found_init , "pid 1 not found in list");
    };
}

fn void test_nonexistent_pid_fails() @test {
    @pool() {
        if (try test = get_proc(tmem, 999999999)) {
            unreachable("expected error for nonexistent pid");
        }
    };
}

fn void test_pid1_partial_info() @test {
    @pool() {
        ProcessInfo? pi = get_info(tmem, 1);
        if (catch pi) return;
        assert (pi.process.pid == 1 , "pid field must match");
        assert (pi.process.name.len > 0 , "process name must not be empty");
    };
}

fn void test_exists_valid() @test {
    @pool() {
        assert (exists(1) , "pid 1 must always exist");
        assert (!exists(999999999) , "nonexistent pid must not exist");
    };
}

fn void test_process_poller_dead_pid_fails() @test {
    @pool() {
        if (try test = process_poller_new(999999999)) {
            unreachable("expected error constructing poller for dead pid");
        }
    };
}

fn void test_process_poller_self_cpu_percent() @test {
    @pool() {
        ProcessPoller? poller = process_poller_new(1);
        if (catch poller) return;
        double? pct = poller.cpu_percent();
        if (catch pct) return;
        assert (pct >= 0.0 && pct <= 100.0 , "cpu percent out of range");
    };
}

fn void test_cpu_times_invalid_pid_fails() @test {
    @pool() {
        if (try test = cpu_times(999999999)) {
            unreachable("expected error for nonexistent pid");
        }
    };
}

fn void test_io_counters_invalid_pid_fails() @test {
    @pool() {
        if (try test = io_counters(999999999)) {
            unreachable("expected error for nonexistent pid");
        }
    };
}

fn void test_all_processes_not_empty() @test {
    @pool() {
        Process[]? procs = all_processes(tmem);
        if (catch procs) {
            unreachable("all_processes should always succeed");
        }
        assert (procs.len > 0 , "expected at least one process");
        foreach (p : procs) {
            assert (p.pid > 0 , "all pids must be positive");
        }
    };
}

fn void test_find_by_name_nonexistent_empty() @test {
    @pool() {
        Process[]? procs = find_by_name(tmem, "zzz_nonexistent_process_xyz");
        if (catch procs) {
            unreachable("find_by_name should return empty not error");
        }
        assert (procs.len == 0 , "expected empty result for nonexistent process name");
    };
}
