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
}

struct SwapMemory {
    ulong total;
    ulong used;
    ulong free;
    double percent;
    ulong sin;
    ulong sout;
}

struct MemoryPoller {
    File meminfo;
    File vmstat;
    Allocator allocator;
}

struct MemoryStats {
    VirtualMemory virtual;
    SwapMemory swap;
}

fn MemoryPoller? poller(Allocator allocator) {
    File meminfo = file::open("/proc/meminfo", "r")!;

    File? maybe_vmstat = file::open("/proc/vmstat", "r");

    if (catch err = maybe_vmstat) {
        (void)meminfo.close();
        return err~;
    }

    return {
        .meminfo = meminfo,
        .vmstat = maybe_vmstat,
        .allocator = allocator,
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
    MemoryStats stats = {
        .virtual = parse_virtual_memory(&self.meminfo)!,
        .swap = parse_swap_memory(&self.meminfo, &self.vmstat)!,
    };
    @body(stats);
}

fn void MemoryPoller.close(&self) {
    (void)self.meminfo.close();
    (void)self.vmstat.close();
}

fn VirtualMemory? parse_virtual_memory(File* file) @private => @pool() {
    VirtualMemory vm = { };

    bool found_total     = false;
    bool found_available = false;
    bool found_free      = false;

    while (try line = io::treadline(file)) {
        if (line.len == 0) continue;

        sz? colon = line.index_of_char(':');
        if (catch colon) continue;

        String key   = line[:colon].trim();
        String value = line[colon + 1..].trim().strip_suffix(" kB").trim();

        ulong v = 0;

        switch (key) {
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
                linsys::@try_field(v, value.to_ulong(), "virtualmemory::value", 0);
            default:
                continue;
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

            case "Active":
                vm.active = v;

            case "Inactive":
                vm.inactive = v;

            case "Buffers":
                vm.buffers = v;

            case "Cached":
                vm.cached += v;

            case "SReclaimable":
                vm.cached += v;
                vm.reclaimable = v;

            case "Shmem":
                vm.shared = v;

            case "Slab":
                vm.slab = v;

            case "SwapCached":
                vm.swap_cached = v;

            case "Dirty":
                vm.dirty = v;

            case "Writeback":
                vm.writeback = v;

            case "Mapped":
                vm.mapped = v;

            case "PageTables":
                vm.page_tables = v;

            case "Committed_AS":
                vm.committed = v;

            case "CommitLimit":
                vm.commit_limit = v;
        }
    }

    if (!found_total || !found_available || !found_free) {
        return linsys::PARSE_ERROR~;
    }

    if (vm.available > vm.total || vm.free > vm.total) {
        return linsys::PARSE_ERROR~;
    }

    vm.cached = vm.cached >= vm.shared ? vm.cached - vm.shared : 0;

    vm.used = vm.total - vm.available;

    if (vm.total > 0) {
        vm.percent = ((double)vm.used / (double)vm.total) * 100.0;
    }

    return vm;
}

fn SwapMemory? parse_swap_memory(File* meminfo, File* vmstat) @private => @pool() {
    SwapMemory sm = { };

    bool found_total = false;
    bool found_free  = false;
    bool found_sin   = false;
    bool found_sout  = false;

    while (try line = io::treadline(meminfo)) {
        if (line.len == 0) continue;

        sz? index = line.index_of_char(':');
        if (catch index) continue;

        String key = line[:index].trim();

        if (key != "SwapTotal" && key != "SwapFree") continue;

        String value = line[index + 1..].trim().strip_suffix(" kB").trim();

        ulong v = value.to_ulong()!;

        switch (key) {
            case "SwapTotal":
                sm.total = v;
                found_total = true;

            case "SwapFree":
                sm.free = v;
                found_free = true;
        }

        if (found_total && found_free) break;
    }

    if (!found_total || !found_free || sm.free > sm.total) {
        return linsys::PARSE_ERROR~;
    }

    while (try line = io::treadline(vmstat)) {
        if (line.len == 0) continue;

        sz? index = line.index_of_char(' ');
        if (catch index) continue;

        String key = line[:index].trim();

        if (key != "pswpin" && key != "pswpout") continue;

        ulong v = line[index + 1..].trim().to_ulong()!;

        switch (key) {
            case "pswpin":
                sm.sin = v;
                found_sin = true;

            case "pswpout":
                sm.sout = v;
                found_sout = true;
        }

        if (found_sin && found_sout) break;
    }

    if (!found_sin || !found_sout) {
        return linsys::PARSE_ERROR~;
    }

    sm.used = sm.total - sm.free;

    if (sm.total > 0) {
        sm.percent = ((double)sm.used / (double)sm.total) * 100.0;
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
