import linsys;
import std::io;
import std::core::mem;
import std::core::mem::allocator;
import std::os::posix;

macro void @tracker(; @body(alloc)) {
    @pool() {
        TrackingAllocator tracker;
        tracker.init(tmem);
        defer tracker.free();
        defer if (tracker.has_leaks()) tracker.print_report();

        {
            @body(&tracker);
        }
        assert (!tracker.has_leaks() , "memory leak detected");
    };
}

fn void test_system_cpu_times() @test {
    @assert_leak() {
        SystemCpuTimes? sc = system::cpu_times();
        if (catch sc) return;
    };
}

fn void test_system_cpu_times_percpu() @test {
    @tracker(; Allocator alloc) {
        SystemCpuTimes[]? sc = system::cpu_times_percpu(alloc);
        if (catch sc) return;
        sc.free(alloc);
    };
}

fn void test_system_cpusnapshot() @test {
    @assert_leak() {
        SystemCpuSnapshot? sc = system::cpu_snapshot();
    };
}

fn void test_system_cpu_snapshot_percpu() @test {
    @tracker(; Allocator alloc) {
        SystemCpuSnapshot[]? sc = system::cpu_snapshot_percpu(alloc);
        if (catch sc) return;
        sc.free(alloc);
    };
}

fn void test_system_cpu_count() @test {
    @assert_leak() {
        CpuCount? sc = system::cpu_count();
        if (catch sc) return;
    };
}

fn void test_system_cpu_freq() @test {
    @assert_leak() {
        CpuFreq? sc = system::cpu_freq();
        if (catch sc) return;
    };
}

fn void test_cpu_freq_percpu() @test {
    @tracker(; Allocator alloc) {
        CpuFreq[]? sc = system::cpu_freq_percpu(alloc);
        if (catch sc) return;
        sc.free(alloc);
    };
}

fn void test_cpustats() @test {
    @assert_leak() {
        CpuStats? sc = system::cpu_stats();
        if (catch sc) return;
    };
}

fn void test_loadavg() @test {
    @assert_leak() {
        LoadAvg? sc = system::load_avg();
        if (catch sc) return;
    };
}

fn void test_cpu_info() @test {
    @tracker(; Allocator alloc) {
        CpuInfo[]? sc = system::cpu_info(alloc);
        if (catch sc) return;
        sc.free(alloc);
    };
}

fn void test_cpu_temps() @test {
    @tracker(; Allocator alloc) {
        CpuTemp[]? sc = system::cpu_temps(alloc);
        if (catch sc) return;
        sc.free(alloc);
    };
}

fn void test_net_conn_poller() @test {
    @tracker(; Allocator alloc) {
        NetConnPoller poller = network::poller(alloc)!!;
        poller.close();
    };
}

fn void test_uptime() {
    @assert_leak() {
        double? sc = system::uptime();
        if (catch sc) return;
    };
}

fn void test_hostname() @test {
    @tracker(; Allocator alloc) {
        String? name = system::hostname(alloc);
        if (catch name) return;
        mem::alloc::free(alloc, name);
    };
}

fn void test_kernel_version() @test {
    @tracker(; Allocator alloc) {
        String? ver = system::kernel_version(alloc);
        if (catch ver) return;
        mem::alloc::free(alloc, ver);
    };
}

fn void test_os_release() @test {
    @tracker(; Allocator alloc) {
        String? rel = system::os_release(alloc);
        if (catch rel) return;
        mem::alloc::free(alloc, rel);
    };
}

fn void test_net_io_counters() @test {
    @tracker(; Allocator alloc) {
        NetIoCounters[]? counters = network::io_counters(alloc);
        if (catch counters) return;
        counters.free(alloc);
    };
}

fn void test_boot_time() @test {
    @assert_leak() {
        ulong bt = system::boot_time();
    };
}

fn void test_read_clktck() @test {
    @assert_leak() {
        ulong bt = system::clktck();
    };
}

fn void test_threads() @test {
    @tracker(; Allocator alloc) {
        ThreadInfo[]? s = process::threads(alloc, posix::getpid());
        if (catch s) return;
        s.free(alloc);
    };
}

fn void test_net_if_addr() @test {
    @tracker(; Allocator alloc) {
        NetIfAddr[]? addrs = network::interface_addrs(alloc);
        if (catch addrs) return;
        addrs.free(alloc);
    };
}

fn void test_net_if_stats() @test {
    @tracker(; Allocator alloc) {
        NetIfStats[]? stats = network::interface_stats(alloc);
        if (catch stats) return;
        stats.free(alloc);
    };
}

fn void test_partition() @test {
    @tracker(; Allocator alloc) {
        DiskPartition[]? parts = disk::partitions(alloc);
        if (catch parts) return;
        parts.free(alloc);
    };
}

fn void test_diskusage() @test {
    @assert_leak() {
        DiskUsage? d = disk::usage("/");
        if (catch d) return;
    };
}

fn void test_io_counters() @test {
    @tracker(; Allocator alloc) {
        DiskContext d = { };
        d.init(alloc);
        DiskIoCounters[]? counters = disk::io_counters(alloc, &d);
        d.free();
        if (catch counters) return;
        counters.free(alloc);
    };
}

fn void test_io_poller() @test {
    @tracker(; Allocator alloc) {
        DiskContext d = { };
        d.init(alloc);
        DiskIoPoller poller = disk::poller(alloc, &d)!!;
        poller.close();
        d.free();
    };
}

fn void test_io_poller_poll() @test {
    @tracker(; Allocator alloc) {
        DiskContext d = { };
        d.init(alloc);
        DiskIoPoller poller = disk::poller(alloc, &d)!!;
        poller.@poll(; DiskIoCounters[] disks) {
            assert (disks.len >= 0);
        }!!;
        poller.close();
        d.free();
    };
}

fn void test_disk_io_poller_perdisk() @test {
    @tracker(; Allocator alloc) {
        disk::DiskContext d = { };
        d.init(alloc);
        DiskIoPoller poller = disk::poller(alloc, &d)!!;
        if (catch poller.@poll_perdisk("sda" ; DiskIoCounters dio) {
        }) {
        }
        poller.close();
        d.free();
    };
}

fn void test_disk_context() @test {
    @tracker(; Allocator alloc) {
        disk::DiskContext ctx;
        ctx.init(alloc);
        usz? s = ctx.sector_size("/");
        ctx.free();
        if (catch s) return;
        assert (s > 0);
    };
}

fn void test_cpu_temp() @test {
    @tracker(; Allocator alloc) {
        CpuTemp[]? temps = system::cpu_temps(alloc);
        if (catch temps) return;
        temps.free(alloc);
    };
}

fn void test_sensor_battery() @test {
    @tracker(; Allocator alloc) {
        SensorBattery[]? batteries = sensors::batteries(alloc);
        if (catch batteries) return;
        batteries.free(alloc);
    };
}

fn void test_sensor_fan() @test {
    @tracker(; Allocator alloc) {
        SensorFan[]? fans = sensors::fans(alloc);
        if (catch fans) return;
        fans.free(alloc);
    };
}

fn void test_sensor_temperature() @test {
    @tracker(; Allocator alloc) {
        SensorTemperature[]? temps = sensors::temperatures(alloc);
        if (catch temps) return;
        temps.free(alloc);
    };
}

fn void test_sensor_poller() @test {
    @tracker(; Allocator alloc) {
        SensorPoller poller = sensors::sensor_poller(alloc)!!;
        poller.close();
    };
}

fn void test_fan_poller() @test {
    @tracker(; Allocator alloc) {
        FanPoller poller = sensors::fan_poller(alloc)!!;
        poller.close();
    };
}

fn void test_memory_poller() @test {
    @tracker(; Allocator alloc) {
        MemoryPoller poller = memory::poller(alloc)!!;
        poller.close();
    };
}

fn void test_info() @test {
    @tracker(; Allocator alloc) {
        ProcessInfo? pi = process::info(alloc, posix::getpid());
        if (catch pi) return;
        pi.free(alloc);
    };
}

fn void test_proc() @test {
    @tracker(; Allocator alloc) {
        Process? pi = process::proc(alloc, posix::getpid());
        if (catch pi) return;
        pi.free(alloc);
    };
}

fn void test_read_cmdline() @test {
    @tracker(; Allocator alloc) {
        String? s = process::read_cmdline(alloc, posix::getpid());
        if (catch s) return;
        mem::alloc::free(alloc, s);
    };
}

fn void test_read_exe() @test {
    @tracker(; Allocator alloc) {
        String? s = process::read_exe(alloc, posix::getpid());
        if (catch s) return;
        mem::alloc::free(alloc, s);
    };
}

fn void test_list_pids() @test {
    @tracker(; Allocator alloc) {
        int[]? s = process::list_pids(alloc);
        if (catch s) return;
        mem::alloc::free(alloc, s);
    };
}

fn void test_cwd() @test {
    @tracker(; Allocator alloc) {
        String? s = process::cwd(alloc, posix::getpid());
        if (catch s) return;
        mem::alloc::free(alloc, s);
    };
}

fn void test_fds() @test {
    @tracker(; Allocator alloc) {
        int[]? s = process::fds(alloc, posix::getpid());
        if (catch s) return;
        mem::alloc::free(alloc, s);
    };
}

fn void test_memory_poller_poll_virtual() @test {
    @tracker(; Allocator alloc) {
        MemoryPoller poller = memory::poller(alloc)!!;
        poller.@poll_virtual(; vm) {
            assert (vm.total > 0);
        }!!;
        poller.close();
    };
}

fn void test_memory_poller_poll_swap() @test {
    @tracker(; Allocator alloc) {
        MemoryPoller poller = memory::poller(alloc)!!;
        poller.@poll_swap(; sm) {
            assert (sm.total > 0);
        }!!;

        poller.close();
    };
}

fn void test_all_processes() @test {
    @tracker(; Allocator alloc) {
        Process[]? procs = process::all_processes(alloc);
        if (catch procs) return;
        procs.free(alloc);
    };
}

fn void test_process_poller_cpu_percent() @test {
    @assert_leak() {
        ProcessPoller poller = process::poller(posix::getpid())!!;
        double? pct          = poller.cpu_percent();
        if (catch pct) return;
    };
}

fn void test_process_poller_memory_percent() @test {
    @assert_leak() {
        ProcessPoller poller = process::poller(posix::getpid())!!;
        double? pct          = poller.memory_percent();
        if (catch pct) return;
    };
}

fn void test_process_poller_io_counters() @test {
    @assert_leak() {
        ProcessPoller poller = process::poller(posix::getpid())!!;
        IoCounters? io       = poller.io_counters();
        if (catch io) return;
    };
}

fn void test_process_poller_exists() @test {
    @assert_leak() {
        ProcessPoller poller = process::poller(posix::getpid())!!;
        assert (poller.exists() , "current pid should always exist");
    };
}

fn void test_env_var() @test {
    @tracker(; Allocator alloc) {
        EnvVar[]? vars = process::environ(alloc, 1);
        if (catch vars) return;
        vars.free(alloc);
    };
}

fn void test_memory_map() @test {
    @tracker(; Allocator alloc) {
        MemoryMap[]? mmaps = process::maps(alloc, 1);
        if (catch mmaps) return;
        mmaps.free(alloc);
    };
}

fn void test_open_file() @test {
    @tracker(; Allocator alloc) {
        OpenFile[]? files = process::open_files(alloc, posix::getpid());
        if (catch files) return;
        files.free(alloc);
    };
}

fn void test_rlimit_entry() @test {
    @tracker(; Allocator alloc) {
        RLimitEntry[]? limits = process::rlimits_get(alloc, 1);
        if (catch limits) return;
        limits.free(alloc);
    };
}

fn void test_virtualmemory() @test {
    @assert_leak() {
        VirtualMemory? vm = memory::virtual_memory();
        if (catch vm) return;
    };
}

fn void test_swapmemory() @test {
    @assert_leak() {
        SwapMemory? vm = memory::swap_memory();
        if (catch vm) return;
    };
}
