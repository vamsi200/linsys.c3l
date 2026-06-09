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
    return {
        .meminfo = file::open("/proc/meminfo", "r")!,
        .vmstat = file::open("/proc/vmstat", "r")!,
        .allocator = allocator,
    };
}

macro void? MemoryPoller.@poll_virtual(&self; @body(stats)) {
    @pool() {
        self.meminfo.seek(0, FROM_START)!;
        VirtualMemory stats = parse_virtual_memory(&self.meminfo)!;
        @body(stats);
    };
}

macro void? MemoryPoller.@poll_swap(&self; @body(stats)) {
    @pool() {
        self.meminfo.seek(0, FROM_START)!;
        self.vmstat.seek(0, FROM_START)!;
        SwapMemory stats = parse_swap_memory(&self.meminfo, &self.vmstat)!;
        @body(stats);
    };
}

macro void? MemoryPoller.@poll(&self; @body(stats)) {
    @pool() {
        self.meminfo.seek(0, FROM_START)!;
        self.vmstat.seek(0, FROM_START)!;
        MemoryStats stats = {
            .virtual = parse_virtual_memory(&self.meminfo)!,
            .swap = parse_swap_memory(&self.meminfo, &self.vmstat)!,
        };
        @body(stats);
    };
}

fn void MemoryPoller.close(&self) {
    (void)self.meminfo.close();
    (void)self.vmstat.close();
}

fn VirtualMemory? parse_virtual_memory(File* file) @private {
    VirtualMemory vm = { };

    while (try line = io::treadline(file)) {
        if (line.len == 0) continue;
        sz? colon = line.index_of_char(':');
        if (catch colon) continue;

        String key   = line[:colon].trim();
        String value = line[colon + 1..].trim().strip_suffix(" kB").trim();
        if (key.len == 0 || key.len > 15) continue;
        ulong v = 0;
        linsys::@try_field(v, value.to_ulong(), "virtualmemory::value", 0);

        switch (key) {
            case "MemTotal": vm.total = v;
            case "MemAvailable": vm.available = v;
            case "MemFree": vm.free = v;
            case "Active": vm.active = v;
            case "Inactive": vm.inactive = v;
            case "Buffers": vm.buffers = v;

            // Linux reports cache as Cached + SReclaimable.
            case "Cached": vm.cached += v;
            case "SReclaimable": vm.cached += v; vm.reclaimable = v;

            case "Shmem": vm.shared = v;
            case "Slab": vm.slab = v;
            case "SwapCached": vm.swap_cached = v;
            case "Dirty": vm.dirty = v;
            case "Writeback": vm.writeback = v;
            case "Mapped": vm.mapped = v;
            case "PageTables": vm.page_tables = v;
            case "Committed_AS": vm.committed = v;
            case "CommitLimit": vm.commit_limit = v;
        }
    }

    vm.used = vm.total - vm.available;

    if (vm.total > 0) vm.percent = ((double)vm.used / (double)vm.total) * 100.0;

    return vm;
}

fn SwapMemory? parse_swap_memory(File* meminfo, File* vmstat) @private {
    SwapMemory sm = { };

    while (try line = io::treadline(meminfo)) {
        if (line.len == 0) continue;
        sz? index = line.index_of_char(':');
        if (catch index) continue;
        String key   = line[:index].trim();
        String value = line[index + 1..].trim().strip_suffix(" kB").trim();
        ulong v = 0;
        linsys::@try_field(v, value.to_ulong(), "swapmemory::value", 0);

        switch (key) {
            case "SwapTotal": sm.total = v;
            case "SwapFree": sm.free = v;
        }

        if (sm.total != 0 && sm.free != 0) break;
    }

    while (try line = io::treadline(vmstat)) {
        if (line.len == 0) continue;
        sz? index = line.index_of_char(' ');
        if (catch index) continue;
        String key = line[:index].trim();
	ulong v = 0;
        linsys::@try_field(v, line[index + 1..].trim().to_ulong(), "swapmemory::line", 0);

        switch (key) {
            case "pswpin": sm.sin = v;
            case "pswpout": sm.sout = v;
        }

        if (sm.sin != 0 && sm.sout != 0) break;
    }

    sm.used = sm.total - sm.free;

    if (sm.total > 0) sm.percent = ((double)sm.used / (double)sm.total) * 100.0;

    return sm;
}

fn VirtualMemory? virtual_memory() {
    @pool() {
        File file = file::open("/proc/meminfo", "r")!;
        defer (void)file.close();
        return parse_virtual_memory(&file);
    };
}

fn SwapMemory? swap_memory() {
    @pool() {
        File meminfo = file::open("/proc/meminfo", "r")!;
        defer (void)meminfo.close();
        File vmstat = file::open("/proc/vmstat", "r")!;
        defer (void)vmstat.close();
        return parse_swap_memory(&meminfo, &vmstat);
    };

}
