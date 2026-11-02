module linsys::memory;
import linsys @public;
import std::io;

struct VirtualMemory {
    ulong total;
    ulong available;
    ulong used;
    ulong free;
    double percent;

    ulong active;
    ulong inactive;
    ulong buffers;
    ulong cached;
    ulong shared;
    ulong slab;
    ulong reclaimable;
    ulong swap_cached;
    ulong dirty;
    ulong writeback;
    ulong mapped;
    ulong page_tables;
    ulong committed;
    ulong commit_limit;

    ulong active_anon;
    ulong inactive_anon;
    ulong active_file;
    ulong inactive_file;
    ulong unevictable;
    ulong mlocked;
    ulong sreclaimable;
    ulong sunreclaim;
    ulong anon_pages;
    ulong kernel_stack;
    ulong vmalloc_used;
    ulong hardware_corrupted;

    ulong hugepages_total;
    ulong hugepages_free;
    ulong hugepages_reserved;
    ulong hugepages_surplus;

    ulong hugepage_size;
}

struct SwapMemory {
    ulong total;
    ulong used;
    ulong free;
    double percent;

    ulong sin;
    ulong sout;

    ulong oom_kill;
    ulong pgfault;
    ulong pgmajfault;
}

struct MemoryStats {
    VirtualMemory virtual;
    SwapMemory swap;
}

struct MemoryPoller {
    File meminfo;
    File vmstat;
    Allocator allocator;
    MemoryStats current;
}

fn ulong? kb_to_bytes(ulong value) @private {
    if (value > ulong::max / 1024) {
        return linsys::PARSE_ERROR~;
    }
    return value * 1024;
}

fn ulong? pages_to_bytes(ulong pages, ulong page_size) @private {
    if (page_size == 0 || pages > ulong::max / page_size) {
        return linsys::PARSE_ERROR~;
    }
    return pages * page_size;
}

fn VirtualMemory? parse_virtual_memory(File* file) @private => @pool() {
    VirtualMemory vm = { };

    bool found_total     = false;
    bool found_available = false;
    bool found_free      = false;

    while (try line = io::treadline(file)) {
        if (line.len == 0) continue;

        sz? colon = line.index_of_char(':');
        if (catch colon) {
            linsys::push_error("virtualmemory::line", linsys::PARSE_ERROR);
            continue;
        }

        String key   = line[:colon].trim();
        String value = line[colon + 1..].trim();

        bool is_count = false;

        switch (key) {
            case "HugePages_Total":
            case "HugePages_Free":
            case "HugePages_Rsvd":
            case "HugePages_Surp":
                is_count = true;

            case "MemTotal":
            case "MemAvailable":
            case "MemFree":
            case "Active":
            case "Inactive":
            case "Buffers":
            case "Cached":
            case "SReclaimable":
            case "Shmem":
            case "Slab":
            case "SwapCached":
            case "Dirty":
            case "Writeback":
            case "Mapped":
            case "PageTables":
            case "Committed_AS":
            case "CommitLimit":
            case "Active(anon)":
            case "Inactive(anon)":
            case "Active(file)":
            case "Inactive(file)":
            case "Unevictable":
            case "Mlocked":
            case "SUnreclaim":
            case "AnonPages":
            case "KernelStack":
            case "VmallocUsed":
            case "HardwareCorrupted":
            case "Hugepagesize":
                value = value.strip_suffix(" kB").trim();

            default:
                continue;
        }

        ulong raw = 0;
        ulong v   = 0;

        linsys::@try_field(raw, value.to_ulong(), "virtualmemory::value", 0);

        if (is_count) {
            v = raw;
        } else {
            linsys::@try_field(v, kb_to_bytes(raw), "virtualmemory::bytes", 0);
        }

        switch (key) {
            case "MemTotal":
                vm.total = v;
                found_total = true;

            case "MemAvailable":
                vm.available = v;
                found_available = true;

            case "MemFree":
                vm.free = v;
                found_free = true;

            case "Active": vm.active = v;
            case "Inactive": vm.inactive = v;
            case "Buffers": vm.buffers = v;
            case "Cached": vm.cached = v;
            case "SReclaimable":
                vm.reclaimable = v;
                vm.sreclaimable = v;
            case "Shmem": vm.shared = v;
            case "Slab": vm.slab = v;
            case "SwapCached": vm.swap_cached = v;
            case "Dirty": vm.dirty = v;
            case "Writeback": vm.writeback = v;
            case "Mapped": vm.mapped = v;
            case "PageTables": vm.page_tables = v;
            case "Committed_AS": vm.committed = v;
            case "CommitLimit": vm.commit_limit = v;

            case "Active(anon)": vm.active_anon = v;
            case "Inactive(anon)": vm.inactive_anon = v;
            case "Active(file)": vm.active_file = v;
            case "Inactive(file)": vm.inactive_file = v;
            case "Unevictable": vm.unevictable = v;
            case "Mlocked": vm.mlocked = v;
            case "SUnreclaim": vm.sunreclaim = v;
            case "AnonPages": vm.anon_pages = v;
            case "KernelStack": vm.kernel_stack = v;
            case "VmallocUsed": vm.vmalloc_used = v;
            case "HardwareCorrupted":
                vm.hardware_corrupted = v;

            case "HugePages_Total":
                vm.hugepages_total = v;
            case "HugePages_Free":
                vm.hugepages_free = v;
            case "HugePages_Rsvd":
                vm.hugepages_reserved = v;
            case "HugePages_Surp":
                vm.hugepages_surplus = v;
            case "Hugepagesize":
                vm.hugepage_size = v;
        }
    }

    if (!found_total) {
        return linsys::PARSE_ERROR~;
    }

    // Fallback for older kernels missing MemAvailable
    if (!found_available) {
        vm.available = vm.free + vm.buffers + vm.cached;
    }

    ulong cached_and_buffers = vm.buffers + vm.cached;

    if (vm.total >= (vm.free + cached_and_buffers)) {
        vm.used = vm.total - vm.free - cached_and_buffers;
    } else {
        vm.used = vm.total - vm.available;
    }

    if (vm.total > 0) {
        vm.percent = (double)vm.used / (double)vm.total * 100.0;
    }

    return vm;
}

fn SwapMemory? parse_swap_memory(File* meminfo, File* vmstat) @private => @pool() {
    SwapMemory sm = { };

    bool found_total = false;
    bool found_free  = false;

    while (try line = io::treadline(meminfo)) {
        if (line.len == 0) continue;

        sz? colon = line.index_of_char(':');
        if (catch colon) continue;

        String key = line[:colon].trim();

        if (key != "SwapTotal" && key != "SwapFree") {
            continue;
        }

        String value = line[colon + 1..].trim().strip_suffix(" kB").trim();

        ulong raw   = 0;
        ulong bytes = 0;

        linsys::@try_field(raw, value.to_ulong(), "swapmemory::value", 0);

        linsys::@try_field(bytes, kb_to_bytes(raw), "swapmemory::bytes", 0);

        switch (key) {
            case "SwapTotal":
                sm.total = bytes;
                found_total = true;

            case "SwapFree":
                sm.free = bytes;
                found_free = true;
        }
    }

    if (!found_total) {
        return linsys::PARSE_ERROR~;
    }

    // If total is 0 -- no swap configured, everything is 0.
    if (sm.total == 0) {
        sm.used = 0;
        sm.percent = 0.0;
    } else if (found_free && sm.free <= sm.total) {
        sm.used = sm.total - sm.free;
        sm.percent = (double)sm.used / (double)sm.total * 100.0;
    } else {
        linsys::push_error("swapmemory::free", linsys::PARSE_ERROR);
    }

    ulong page_size = system::get_page_size()!;

    while (try line = io::treadline(vmstat)) {
        if (line.len == 0) continue;

        String[] fields = linsys::split_whitespace(line);
        if (fields.len < 2) continue;

        String key = fields[0];

        if (key != "pswpin" && key != "pswpout" && key != "oom_kill" && key != "pgfault"
            && key != "pgmajfault") {
            continue;
        }

        ulong raw_val = 0;
        linsys::@try_field(raw_val, fields[1].to_ulong(), "vmevents::raw", 0);

        switch (key) {
            case "pswpin":
                linsys::@try_field(
                    sm.sin,
                    pages_to_bytes(raw_val, page_size),
                    "swapmemory::bytes",
                    0
                );
            case "pswpout":
                linsys::@try_field(
                    sm.sout,
                    pages_to_bytes(raw_val, page_size),
                    "swapmemory::bytes",
                    0
                );
            case "oom_kill":
                sm.oom_kill = raw_val;
            case "pgfault":
                sm.pgfault = raw_val;
            case "pgmajfault":
                sm.pgmajfault = raw_val;
        }
    }

    return sm;
}

fn VirtualMemory? virtual_memory() => @pool() {
    File file = file::open("/proc/meminfo", "r")!;
    defer (void)file.close();

    return parse_virtual_memory(&file);
}

fn SwapMemory? swap_memory() => @pool() {
    File meminfo = file::open("/proc/meminfo", "r")!;
    defer (void)meminfo.close();

    File vmstat = file::open("/proc/vmstat", "r")!;
    defer (void)vmstat.close();

    return parse_swap_memory(&meminfo, &vmstat);
}

fn MemoryPoller? poller(Allocator allocator) {
    File meminfo       = file::open("/proc/meminfo", "r")!;
    File? maybe_vmstat = file::open("/proc/vmstat", "r");

    if (catch err = maybe_vmstat) {
        (void)meminfo.close();
        return err~;
    }

    return {
        .meminfo = meminfo,
        .vmstat = maybe_vmstat,
        .allocator = allocator,
        .current = {}
    };
}

macro void? MemoryPoller.@poll_virtual(&self; @body(stats)) => @pool() {
    self.meminfo.seek(0, FROM_START)!;

    VirtualMemory stats = parse_virtual_memory(&self.meminfo)!;

    @body(stats);
}

macro void? MemoryPoller.@poll_swap(&self; @body(stats)) => @pool() {
    self.meminfo.seek(0, FROM_START)!;
    self.vmstat.seek(0, FROM_START)!;

    SwapMemory stats = parse_swap_memory(&self.meminfo, &self.vmstat)!;

    @body(stats);
}

macro void? MemoryPoller.@poll(&self; @body(stats)) => @pool() {
    self.meminfo.seek(0, FROM_START)!;
    self.vmstat.seek(0, FROM_START)!;

    VirtualMemory vm = parse_virtual_memory(&self.meminfo)!;
    self.meminfo.seek(0, FROM_START)!;

    SwapMemory sm = parse_swap_memory(&self.meminfo, &self.vmstat)!;

    self.current = {
        .virtual = vm,
        .swap = sm,
    };

    @body(self.current);
}

fn void MemoryPoller.close(&self) {
    (void)self.meminfo.close();
    (void)self.vmstat.close();
}

struct KsmMemory {
    ulong shared_bytes;
    ulong sharing_bytes;
    ulong unshared_bytes;
    ulong volatile_bytes;
    ulong full_scans;
}

// Returns NOT_FOUND if the kernel was compiled without CONFIG_KSM
fn KsmMemory? ksm_memory() {
    ulong page_size = system::get_page_size()!;
    KsmMemory ksm   = { };

    ulong? shared = linsys::read_ulong_file("/sys/kernel/mm/ksm/pages_shared");
    if (catch err = shared) return linsys::NOT_FOUND~;

    ksm.shared_bytes = shared * page_size;

    ulong? sharing = linsys::read_ulong_file("/sys/kernel/mm/ksm/pages_sharing");
    if (catch err = sharing) {
    } else {
        ksm.sharing_bytes = sharing * page_size;
    }

    ulong? unshared = linsys::read_ulong_file("/sys/kernel/mm/ksm/pages_unshared");
    if (catch err = unshared) {
    } else {
        ksm.unshared_bytes = unshared * page_size;
    }

    ulong? vol = linsys::read_ulong_file("/sys/kernel/mm/ksm/pages_volatile");
    if (catch err = vol) {
    } else {
        ksm.volatile_bytes = vol * page_size;
    }

    ulong? scans = linsys::read_ulong_file("/sys/kernel/mm/ksm/full_scans");
    if (catch err = scans) {
    } else {
        ksm.full_scans = scans;
    }

    return ksm;
}

// tests
fn void test_memory_kb_to_bytes_overflow() @test {
    ulong? bytes = kb_to_bytes(ulong::max);

    if (catch err = bytes) {
        assert(err == linsys::PARSE_ERROR);
    } else {
        assert(false);
    }
}

fn void test_memory_virtual_memory() @test {
    linsys::@tracker(; Allocator alloc) {
        VirtualMemory? vm_opt = virtual_memory();
        if (catch err = vm_opt) return;

        assert(vm_opt.total > 0);
        assert(vm_opt.available > 0);

        assert(vm_opt.used <= vm_opt.total);
        assert(vm_opt.percent >= 0.0 && vm_opt.percent <= 100.0);
    };
}

fn void test_memory_swap_memory() @test {
    linsys::@tracker(; Allocator alloc) {
        SwapMemory? sm_opt = swap_memory();
        if (catch err = sm_opt) return;

        assert(sm_opt.percent >= 0.0 && sm_opt.percent <= 100.0);
        assert(sm_opt.used <= sm_opt.total);
    };
}

fn void test_memory_poller() @test {
    linsys::@tracker(; Allocator alloc) {
        MemoryPoller poller = memory::poller(alloc)!!;
        poller.close();
    };
}

fn void test_memory_poller_poll_virtual() @test {
    linsys::@tracker(; Allocator alloc) {
        MemoryPoller poller = memory::poller(alloc)!!;
        poller.@poll_virtual(; vm) {
            assert(vm.total > 0);
        }!!;
        poller.close();
    };
}

fn void test_memory_poller_poll_swap() @test {
    linsys::@tracker(; Allocator alloc) {
        MemoryPoller poller = memory::poller(alloc)!!;
        poller.@poll_swap(; sm) {
            assert(sm.total > 0);
        }!!;

        poller.close();
    };
}

