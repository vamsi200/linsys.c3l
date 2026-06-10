module linsys::system;
import linsys @public;
import std::io;
import std::io::file;
import libc;
import std::core::string;
import std::collections::list;
import std::net;
import std::os::posix;
import std::thread;

struct SystemCpuTimes {
    double user;
    double nice;
    double system;
    double idle;
    double iowait;
    double irq;
    double softirq;
    double steal;
    double guest;
    double guest_nice;
}

struct SystemCpuSnapshot {
    ulong total;
    ulong idle;
}

struct CpuCount {
    int logical;
    int physical;
}

struct CpuFreq {
    double current;
    double min;
    double max;
}

struct CpuStats {
    ulong ctx_switches;
    ulong interrupts;
    ulong soft_interrupts;
    ulong syscalls;
}

struct LoadAvg {
    double one;
    double five;
    double fifteen;
}

struct CpuInfo {
    String vendor;
    String model;
    double mhz;
    int cache_size;
    int cores;
    int siblings;
    String flags;
}

struct CpuUsage {
    double user_percent;
    double system_percent;
    double idle_percent;
    double iowait_percent;
}

struct CpuTemp {
    String sensor;
    double current;
    double critical;
}

fn SystemCpuTimes? cpu_times() {
    @pool() {
        File file = file::open("/proc/stat", "r")!;
        defer (void)file.close();
        String line  = io::treadline(&file)!;
        String[] raw = linsys::split_whitespace(tmem, line);

        ulong user, nice, system, idle, iowait, irq, softirq, steal, guest, guest_nice;

        if (raw.len > 1) linsys::@try_field(user, raw[1].to_ulong(), "systemcputimes::user", 0);
        if (raw.len > 2) linsys::@try_field(nice, raw[2].to_ulong(), "systemcputimes::nice", 0);
        if (raw.len > 3) linsys::@try_field(system, raw[3].to_ulong(), "systemcputimes::system", 0);
        if (raw.len > 4) linsys::@try_field(idle, raw[4].to_ulong(), "systemcputimes::idle", 0);
        if (raw.len > 5) linsys::@try_field(iowait, raw[5].to_ulong(), "systemcputimes::iowait", 0);
        if (raw.len > 6) linsys::@try_field(irq, raw[6].to_ulong(), "systemcputimes::irq", 0);
        if (raw.len > 7) linsys::@try_field(
            softirq,
            raw[7].to_ulong(),
            "systemcputimes::softirq",
            0
        );
        if (raw.len > 8) linsys::@try_field(steal, raw[8].to_ulong(), "systemcputimes::steal", 0);
        if (raw.len > 9) linsys::@try_field(guest, raw[9].to_ulong(), "systemcputimes::guest", 0);
        if (raw.len > 10) linsys::@try_field(
            guest_nice,
            raw[10].to_ulong(),
            "systemcputimes::guest_nice",
            0
        );

        user -= guest;
        nice -= guest_nice;

        return {
            .user = user,
            .nice = nice,
            .system = system,
            .idle = idle,
            .iowait = iowait,
            .irq = irq,
            .softirq = softirq,
            .steal = steal,
            .guest = guest,
            .guest_nice = guest_nice,
        };
    };
}

fn SystemCpuTimes[]? cpu_times_percpu(Allocator allocator) {
    @pool() {
        File file = file::open("/proc/stat", "r")!;
        defer (void)file.close();

        List{SystemCpuTimes} cpus;
        cpus.init(allocator);
        defer cpus.free();

        while (try line = io::treadline(&file)) {
            if (!line.starts_with("cpu")) {
                continue;
            }

            if (line.starts_with("cpu ")) {
                continue;
            }

            String[] fields = line.split(tmem, " ");

            if (fields.len < 11) {
                linsys::push_error("systemcputimes::line", linsys::PARSE_ERROR);
                continue;
            }

            ulong user, nice, system, idle, iowait, irq, softirq, steal, guest, guest_nice;

            if (fields.len < 4) linsys::push_error("systemcputimes::line", linsys::PARSE_ERROR);
            if (fields.len > 1) linsys::@try_field(
                user,
                fields[1].to_ulong(),
                "systemcputimes::user",
                0
            );
            if (fields.len > 2) linsys::@try_field(
                nice,
                fields[2].to_ulong(),
                "systemcputimes::nice",
                0
            );
            if (fields.len > 3) linsys::@try_field(
                system,
                fields[3].to_ulong(),
                "systemcputimes::system",
                0
            );
            if (fields.len > 4) linsys::@try_field(
                idle,
                fields[4].to_ulong(),
                "systemcputimes::idle",
                0
            );
            if (fields.len > 5) linsys::@try_field(
                iowait,
                fields[5].to_ulong(),
                "systemcputimes::iowait",
                0
            );
            if (fields.len > 6) linsys::@try_field(
                irq,
                fields[6].to_ulong(),
                "systemcputimes::irq",
                0
            );
            if (fields.len > 7) linsys::@try_field(
                softirq,
                fields[7].to_ulong(),
                "systemcputimes::softirq",
                0
            );
            if (fields.len > 8) linsys::@try_field(
                steal,
                fields[8].to_ulong(),
                "systemcputimes::steal",
                0
            );
            if (fields.len > 9) linsys::@try_field(
                guest,
                fields[9].to_ulong(),
                "systemcputimes::guest",
                0
            );
            if (fields.len > 10) linsys::@try_field(
                guest_nice,
                fields[10].to_ulong(),
                "systemcputimes::guest_nice",
                0
            );

            cpus.push(
                {
                    .user = user,
                    .nice = nice,
                    .system = system,
                    .idle = idle,
                    .iowait = iowait,
                    .irq = irq,
                    .softirq = softirq,
                    .steal = steal,
                    .guest = guest,
                    .guest_nice = guest_nice,
                }
            );
        }

        return cpus.to_array(allocator);
    };
}

fn void SystemCpuTimes[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void SystemCpuTimes.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

fn SystemCpuSnapshot? cpu_snapshot() {
    @pool() {
        File file = file::open("/proc/stat", "r")!;
        defer (void)file.close();
        String line = io::treadline(&file)!;

        if (line.starts_with("cpu ")) {
            String[] fields = linsys::split_whitespace(tmem, line);
            ulong total     = 0;
            ulong idle      = 0;

            foreach (field : fields[1..]) {
                total += field.to_ulong()!;
            }

            if (fields.len > 4) idle = fields[4].to_ulong()!;

            // io_wait also included..
            if (fields.len > 5) idle += fields[5].to_ulong()!;

            return { .total = total, .idle = idle, };
        }

        return linsys::PARSE_ERROR~;
    };
}

fn SystemCpuSnapshot[]? cpu_snapshot_percpu(Allocator allocator) {
    @pool() {
        File file = file::open("/proc/stat", "r")!;
        defer (void)file.close();
        List{SystemCpuSnapshot} cs;
        cs.init(allocator);
        defer cs.free();

        ulong total = 0;
        ulong idle  = 0;

        while (try line = io::treadline(&file)) {
            if (!line.starts_with("cpu")) continue;
            if (line.starts_with("cpu ")) continue;

            String[] fields = linsys::split_whitespace(tmem, line);

            foreach (field : fields[1..]) {
                total += field.to_ulong() ?? 0;
            }

            if (fields.len > 4) idle = fields[4].to_ulong() ?? 0;

            if (fields.len > 5) idle += fields[5].to_ulong() ?? 0;

            cs.push({ .total = total, .idle = idle });
        }

        return cs.to_array(allocator);
    };
}

fn void SystemCpuSnapshot[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void SystemCpuSnapshot.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

fn double cpu_percent(SystemCpuSnapshot old, SystemCpuSnapshot new) {
    ulong total_delta = new.total - old.total;
    ulong idle_delta  = new.idle - old.idle;

    if (total_delta == 0) {
        return 0.0;
    }

    return ((double)(total_delta - idle_delta) / (double)total_delta) * 100.0;
}

<*
 @require new.len == old.len : "snapshot arrays must be same length"
*>
fn double[]? cpu_percent_percpu(
    Allocator allocator,
    SystemCpuSnapshot[] old,
    SystemCpuSnapshot[] new
) {
    double[] out = mem::alloc::alloc_array(allocator, double, old.len);

    foreach (i, o : old) {
        SystemCpuSnapshot n = new[i];

        ulong total_delta = n.total - o.total;
        ulong idle_delta  = n.idle - o.idle;

        if (total_delta == 0) {
            out[i] = 0.0;
            continue;
        }

        out[i] = ((double)(total_delta - idle_delta) / (double)total_delta) * 100.0;
    }

    return out;
}

fn CpuCount? cpu_count() {
    @pool() {
        File file = file::open("/proc/cpuinfo", "r")!;
        defer (void)file.close();
        int logical = 0;

        List{int} physical_ids;
        physical_ids.init(tmem);
        defer physical_ids.free();

        while (try line = io::treadline(&file)) {
            if (line.starts_with("processor")) {
                logical++;
            }

            if (!line.starts_with("physical id")) {
                continue;
            }

            String[] split = line.split(tmem, ":");

            if (split.len < 2) {
                continue;
            }

            if (try int id = split[1].trim().to_int()) {
                bool exists = false;

                foreach (pid : physical_ids) {
                    if (pid == id) {
                        exists = true;
                        break;
                    }
                }

                if (!exists) {
                    physical_ids.push(id);
                }
            }
        }

        return { .logical = logical, .physical = (int)physical_ids.len(), };
    };
}

fn void CpuFreq[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void CpuFreq.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

fn CpuFreq? cpu_freq() {
    @pool() {
        String cur_path = "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq";
        String min_path = "/sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq";
        String max_path = "/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq";

        CpuFreq cf = { };

        File cur = file::open(cur_path, "r")!;
        defer (void)cur.close();

        File min = file::open(min_path, "r")!;
        defer (void)min.close();

        File max = file::open(max_path, "r")!;
        defer (void)max.close();

        cf.current = ((double)(linsys::read_file(tmem, cur)!.trim().to_ulong() ?? 0) / 1000.0);

        cf.min = ((double)(linsys::read_file(tmem, min)!.trim().to_ulong() ?? 0) / 1000.0);

        cf.max = ((double)(linsys::read_file(tmem, max)!.trim().to_ulong() ?? 0) / 1000.0);

        return cf;
    };
}


fn CpuFreq[]? cpu_freq_percpu(Allocator allocator) {
    @pool() {
        Path path = path::new(tmem, "/sys/devices/system/cpu")!;

        PathList list = io::path::ls(tmem, path)!;

        List{CpuFreq} freqs;
        freqs.init(allocator);
        defer freqs.free();

        foreach (entry : list) {
            String name = entry.file_tbasename()!;

            if (!name.starts_with("cpu") || name == "cpufreq") continue;

            if (try name[3..].to_int()) {
                String base = string::tformat("/sys/devices/system/cpu/%s/cpufreq", name);

                String cur_path = string::tformat("%s/scaling_cur_freq", base);

                String min_path = string::tformat("%s/scaling_min_freq", base);

                String max_path = string::tformat("%s/scaling_max_freq", base);

                File? cur = file::open(cur_path, "r");
                if (catch cur) continue;
                defer (void)cur.close();

                File? min = file::open(min_path, "r");
                if (catch min) continue;

                defer (void)min.close();

                File? max = file::open(max_path, "r");
                if (catch max) continue;
                defer (void)max.close();

                String cur_content = linsys::read_file(tmem, cur) ?? "".copy(allocator);
                String min_content = linsys::read_file(tmem, min) ?? "".copy(allocator);
                String max_content = linsys::read_file(tmem, max) ?? "".copy(allocator);

                ulong cur_val, min_val, max_val;
                linsys::@try_field(cur_val, (linsys::read_file(tmem, cur) ?? "").trim()
                    .to_ulong(), "cpufreq::current", 0);
                linsys::@try_field(min_val, (linsys::read_file(tmem, min) ?? "").trim()
                    .to_ulong(), "cpufreq::min", 0);
                linsys::@try_field(max_val, (linsys::read_file(tmem, max) ?? "").trim()
                    .to_ulong(), "cpufreq::max", 0);

                freqs.push(
                    {
                        .current = cur_val / 1000.0,
                        .min = min_val / 1000.0,
                        .max = max_val / 1000.0
                    }
                );
            }
        }

        return freqs.to_array(allocator);
    };
}

fn CpuStats? cpu_stats() {
    @pool() {
        File file = file::open("/proc/stat", "r")!;
        defer (void)file.close();
        CpuStats stats = { };

        while (try line = io::treadline(&file)) {
            String[] fields = linsys::split_whitespace(tmem, line);

            if (fields.len < 2) {
                linsys::push_error("cpustats::line", linsys::PARSE_ERROR);
                continue;
            }

            switch (fields[0]) {
                case "ctxt":
                    linsys::@try_field(
                        stats.ctx_switches,
                        fields[1].to_ulong(),
                        "cpustats::ctx_switches",
                        0
                    );
                case "intr":
                    linsys::@try_field(
                        stats.interrupts,
                        fields[1].to_ulong(),
                        "cpustats::interrupts",
                        0
                    );
                case "softirq":
                    linsys::@try_field(
                        stats.soft_interrupts,
                        fields[1].to_ulong(),
                        "cpustats::soft_interrupts",
                        0
                    );
                case "syscalls":
                    linsys::@try_field(
                        stats.syscalls,
                        fields[1].to_ulong(),
                        "cpustats::syscalls",
                        0
                    );
            }
        }

        return stats;
    };
}


fn LoadAvg? load_avg() {
    @pool() {
        File file = file::open("/proc/loadavg", "r")!;
        defer (void)file.close();

        while (try line = io::treadline(&file)) {
            String[] fields = linsys::split_whitespace(tmem, line);

            if (fields.len < 3) {
                return linsys::PARSE_ERROR~;
            }

            double one, five, fifteen;
            linsys::@try_field(one, fields[0].to_double(), "loadavg::one", 0);
            linsys::@try_field(five, fields[1].to_double(), "loadavg::five", 0);
            linsys::@try_field(fifteen, fields[2].to_double(), "loadavg::fifteen", 0);
            return { .one = one, .five = five, .fifteen = fifteen };
        }
    };

    return linsys::UNKNOWN~;
}

fn CpuInfo[]? cpu_info(Allocator allocator) {
    @pool() {
        File file = file::open("/proc/cpuinfo", "r")!;
        defer (void)file.close();
        List{CpuInfo} infos;
        infos.init(allocator);
        defer infos.free();
        CpuInfo current = { };

        while (try line = io::treadline(&file)) {
            if (line.len == 0) {
                infos.push(current);
                current = { };
                continue;
            }

            String[] split = line.split(tmem, ":");

            if (split.len < 2) {
                continue;
            }

            String key = split[0].trim();
            String val = split[1].trim();

            switch (key) {
                case "vendor_id":
                    current.vendor = val.copy(allocator);
                case "model name":
                    current.model = val.copy(allocator);
                case "cpu MHz":
                    linsys::@try_field(current.mhz, val.to_double(), "cpuinfo::mhz", 0);
                case "cache size":
                    String size = val.strip_suffix(" KB").trim();
                    linsys::@try_field(current.cache_size, size.to_int(), "cpuinfo::cache_size", 0);
                case "cpu cores":
                    linsys::@try_field(current.cores, val.to_int(), "cpuinfo::cores", 0);
                case "siblings":
                    linsys::@try_field(current.siblings, val.to_int(), "cpuinfo::siblings", 0);
                case "flags":
                    current.flags = val.copy(allocator);
            }
        }

        if (current.model.len > 0 || current.vendor.len > 0) infos.push(current);

        return infos.to_array(allocator);
    };
}

fn void CpuInfo[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void CpuInfo.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

fn CpuTemp[]? cpu_temps(Allocator allocator) {
    @pool() {
        Path path = path::new(tmem, "/sys/class/thermal")!;

        PathList list = io::path::ls(tmem, path)!;

        List{CpuTemp} temps;
        temps.init(allocator);
        defer temps.free();

        foreach (entry : list) {
            String name = entry.file_tbasename()!;

            if (!name.starts_with("thermal_zone")) continue;

            String base = string::tformat("/sys/class/thermal/%s", name);

            String temp_path = string::tformat("%s/temp", base);

            String type_path = string::tformat("%s/type", base);

            File? tf = file::open(temp_path, "r");
            if (catch tf) continue;
            defer (void)tf.close();

            File? ty = file::open(type_path, "r");
            if (catch ty) continue;
            defer (void)ty.close();

            double current = ((double)(linsys::read_file(tmem, tf)!.trim()
                .to_long() ?? 0) / 1000.0);

            String sensor = linsys::read_file(tmem, ty)!.trim().copy(allocator);

            temps.push({ .sensor = sensor, .current = current, .critical = 0.0, });
        }

        return temps.to_array(allocator);
    };
}

fn void CpuTemp[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void CpuTemp.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

fn CpuUsage cpu_usage(SystemCpuTimes old, SystemCpuTimes new) {
    double old_total = old.user + old.nice + old.system + old.idle + old.iowait + old.irq
        + old.softirq
        + old.steal;

    double new_total = new.user + new.nice + new.system + new.idle + new.iowait + new.irq
        + new.softirq
        + new.steal;

    double total_delta = new_total - old_total;

    if (total_delta <= 0.0) {
        return { };
    }

    return {
        .user_percent = ((new.user - old.user) / total_delta) * 100.0,
        .system_percent = ((new.system - old.system) / total_delta) * 100.0,
        .idle_percent = ((new.idle - old.idle) / total_delta) * 100.0,
        .iowait_percent = ((new.iowait - old.iowait) / total_delta) * 100.0,
    };
}

fn double? uptime() {
    @pool() {
        File file = file::open("/proc/uptime", "r")!;
        defer (void)file.close();
        String content  = linsys::read_file(tmem, file)!;
        String[] fields = linsys::split_whitespace(tmem, content.trim());
        if (fields.len < 1) return linsys::NOT_FOUND~;
        return fields[0].to_double();
    };
}

fn String? hostname(Allocator allocator) {
    File file = file::open("/proc/sys/kernel/hostname", "r")!;
    defer (void)file.close();
    return linsys::read_file(tmem, file)!.trim().copy(allocator);
}

fn String? kernel_version(Allocator allocator) {
    File file = file::open("/proc/sys/kernel/osrelease", "r")!;
    defer (void)file.close();
    return linsys::read_file(tmem, file)!.trim().copy(allocator);
}

fn String? os_release(Allocator allocator) {
    File file = file::open("/etc/os-release", "r")!;
    defer (void)file.close();

    while (try line = io::treadline(&file)) {
        if (!line.starts_with("PRETTY_NAME=")) continue;
        String val = line.strip_prefix("PRETTY_NAME=").trim();
        if (val.len >= 2 && val[0] == '"' && val[val.len - 1] == '"') {
            val = val[1:val.len - 2];
        }
        return val.copy(allocator);
    }
    return linsys::NOT_FOUND~;
}

macro ulong boot_time() {
    static ulong cached = 0;
    if (cached == 0) cached = read_boot_time() ?? 0;
    return cached;
}

fn ulong? read_boot_time() @private {
    File file = file::open("/proc/stat", "r")!;
    defer (void)file.close();
    ulong btime;

    while (try line = io::treadline(&file)) {
        if (line.contains("btime")) {
            String s = line.strip_prefix("btime ");
            btime = s.to_ulong()!;
            break;
        }
    }

    return btime;
}

macro ulong clktck() {
    static ulong cached = 0;
    if (cached == 0) cached = read_clktck() ?? 100;
    return cached;
}

// getconf CLK_TCK
fn ulong? read_clktck() @private {
    File file = file::open("/proc/self/auxv", "rb")!;
    defer (void)file.close();
    char[4096] buf;
    sz n = file.read(&buf)!;

    sz i = 0;
    while (i + 16 <= n) {
        ulong type, val;
        mem::copy(&type, &buf[i], 8);
        mem::copy(&val, &buf[i + 8], 8);

        if (type == 17) return val; // AT_CLKTCK
        if (type == 0) break; // AT_NULL
        i += 16;
    }
    return 100;
}
