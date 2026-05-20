import std::io;
import proc;

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


fn VirtualMemory? virtual_memory() {
    @pool() {
        File file = file::open("/proc/meminfo", "r")!;
        defer (void)file.close();

        String content = proc::read_file(tmem, file)!;

        VirtualMemory vm = { };

        foreach (line : content.split(tmem, "\n")) {
            String[] split = line.split(tmem, ":");

            if (split.len < 2) {
                continue;
            }

            String key = split[0].trim();

            String value = split[1].trim().strip_suffix(" kB").trim();

            ulong v = value.to_ulong() ?? 0;

            switch (key) {
                case "MemTotal":
                    vm.total = v;

                case "MemAvailable":
                    vm.available = v;

                case "MemFree":
                    vm.free = v;

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

        vm.used = vm.total - vm.available;

        if (vm.total > 0) {
            vm.percent = ((double)vm.used / (double)vm.total) * 100.0;
        }

        return vm;
    };
}


fn SwapMemory? swap_memory() {
    @pool() {
        SwapMemory sm = { };

        File meminfo = file::open("/proc/meminfo", "r")!;
        defer (void)meminfo.close();

        String mem = proc::read_file(tmem, meminfo)!;

        foreach (line : mem.split(tmem, "\n")) {
            String[] split = line.split(tmem, ":");

            if (split.len < 2) {
                continue;
            }

            String key = split[0].trim();

            String value = split[1].trim().strip_suffix(" kB").trim();

            ulong v = value.to_ulong() ?? 0;

            switch (key) {
                case "SwapTotal":
                    sm.total = v;

                case "SwapFree":
                    sm.free = v;
            }
        }

        sm.used = sm.total - sm.free;

        if (sm.total > 0) {
            sm.percent = ((double)sm.used / (double)sm.total) * 100.0;
        }

        File vmstat = file::open("/proc/vmstat", "r")!;
        defer (void)vmstat.close();

        String vm = proc::read_file(tmem, vmstat)!;

        foreach (line : vm.split(tmem, "\n")) {
            String[] fields = line.split(tmem, " ");

            if (fields.len < 2) {
                continue;
            }

            switch (fields[0]) {
                case "pswpin":
                    sm.sin = fields[1].to_ulong() ?? 0;

                case "pswpout":
                    sm.sout = fields[1].to_ulong() ?? 0;
            }
        }

        return sm;
    };
}
