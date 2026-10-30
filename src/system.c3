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
import std::collections::maybe;

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
    Maybe{ulong} syscalls;
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

struct ThermalZones {
    String sensor;
    double current;
    double critical;
}

struct PressureMetrics {
    double avg10;
    double avg60;
    double avg300;
    ulong total;
}

struct PressureInfo {
    PressureMetrics some;
    PressureMetrics full;
}

fn PressureInfo? parse_psi(String content, String ctx) @private {
    PressureInfo info = { };
    String[] lines    = content.split(tmem, "\n");

    foreach (line : lines) {
        if (line.len == 0) continue;

        String[] fields = linsys::split_whitespace(line);
        if (fields.len == 0) continue;

        PressureMetrics* metrics;
        switch (fields[0]) {
            case "some": metrics = &info.some;
            case "full": metrics = &info.full;
            default: continue;
        }

        for (int i = 1; i < fields.len; i++) {
            String[] kv = fields[i].split(tmem, "=");
            if (kv.len != 2) {
                linsys::push_error(ctx, linsys::PARSE_ERROR);
                continue;
            }

            switch (kv[0]) {
                case "avg10":
                    linsys::@try_field(metrics.avg10, kv[1].to_double(), ctx, 0);
                case "avg60":
                    linsys::@try_field(metrics.avg60, kv[1].to_double(), ctx, 0);
                case "avg300":
                    linsys::@try_field(metrics.avg300, kv[1].to_double(), ctx, 0);
                case "total":
                    linsys::@try_field(metrics.total, kv[1].to_ulong(), ctx, 0);
                default: break;
            }
        }
    }

    return info;
}

fn PressureInfo? psi_cpu() => @pool() {
    File file = file::open("/proc/pressure/cpu", "r")!;
    defer (void)file.close();
    String content = linsys::read_file(file)!;
    return parse_psi(content, "psi_cpu");
}

fn PressureInfo? psi_memory() => @pool() {
    File file = file::open("/proc/pressure/memory", "r")!;
    defer (void)file.close();
    String content = linsys::read_file(file)!;
    return parse_psi(content, "psi_memory");
}

fn PressureInfo? psi_io() => @pool() {
    File file = file::open("/proc/pressure/io", "r")!;
    defer (void)file.close();
    String content = linsys::read_file(file)!;
    return parse_psi(content, "psi_io");
}

fn SystemCpuTimes? cpu_times() => @pool() {
    File file = file::open("/proc/stat", "r")!;
    defer (void)file.close();
    String line  = io::treadline(&file)!;
    String[] raw = linsys::split_whitespace(line);

    ulong user, nice, system, idle, iowait, irq, softirq, steal, guest, guest_nice;

    if (raw.len > 1) linsys::@try_field(user, raw[1].to_ulong(), "systemcputimes::user", 0);
    if (raw.len > 2) linsys::@try_field(nice, raw[2].to_ulong(), "systemcputimes::nice", 0);
    if (raw.len > 3) linsys::@try_field(system, raw[3].to_ulong(), "systemcputimes::system", 0);
    if (raw.len > 4) linsys::@try_field(idle, raw[4].to_ulong(), "systemcputimes::idle", 0);
    if (raw.len > 5) linsys::@try_field(iowait, raw[5].to_ulong(), "systemcputimes::iowait", 0);
    if (raw.len > 6) linsys::@try_field(irq, raw[6].to_ulong(), "systemcputimes::irq", 0);
    if (raw.len > 7) linsys::@try_field(softirq, raw[7].to_ulong(), "systemcputimes::softirq", 0);
    if (raw.len > 8) linsys::@try_field(steal, raw[8].to_ulong(), "systemcputimes::steal", 0);
    if (raw.len > 9) linsys::@try_field(guest, raw[9].to_ulong(), "systemcputimes::guest", 0);
    if (raw.len > 10) linsys::@try_field(
        guest_nice,
        raw[10].to_ulong(),
        "systemcputimes::guest_nice",
        0
    );

    if (guest <= user) {
        user -= guest;
    } else {
        linsys::push_error("systemcputimes::guest", linsys::PARSE_ERROR);
    }

    if (guest_nice <= nice) {
        nice -= guest_nice;
    } else {
        linsys::push_error("systemcputimes::guest", linsys::PARSE_ERROR);
    }

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
}

fn SystemCpuTimes[]? cpu_times_percpu(Allocator allocator) => @pool() {
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
        if (fields.len > 6) linsys::@try_field(irq, fields[6].to_ulong(), "systemcputimes::irq", 0);
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
}

fn void SystemCpuTimes[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void SystemCpuTimes.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

fn SystemCpuSnapshot? cpu_snapshot() => @pool() {
    File file = file::open("/proc/stat", "r")!;
    defer (void)file.close();
    String line = io::treadline(&file)!;

    if (line.starts_with("cpu ")) {
        String[] fields = linsys::split_whitespace(line);
        ulong idle      = 0;
        ulong total     = cpu_total_ticks(fields)!;

        if (fields.len > 4) idle = fields[4].to_ulong()!;

        // io_wait also included..
        if (fields.len > 5) idle += fields[5].to_ulong()!;

        return {
            .total = total,
            .idle = idle,
        };
    }

    return linsys::PARSE_ERROR~;
}

fn ulong? cpu_total_ticks(String[] fields) @private {
    if (fields.len < 5) return linsys::PARSE_ERROR~;

    ulong total = 0;

    // user, nice, system, idle, iowait, irq, softirq, steal
    for (usz i = 1; i < fields.len && i <= 8; i++) {
        total += fields[i].to_ulong()!;
    }

    return total;
}

fn SystemCpuSnapshot[]? cpu_snapshot_percpu(Allocator allocator) => @pool() {
    File file = file::open("/proc/stat", "r")!;
    defer (void)file.close();
    List{SystemCpuSnapshot} cs;
    cs.init(allocator);
    defer cs.free();

    while (try line = io::treadline(&file)) {
        if (!line.starts_with("cpu") || line.starts_with("cpu ")) continue;

        String[] fields = linsys::split_whitespace(line);
        if (fields.len < 5) {
            linsys::push_error("systemcputimes::line", linsys::PARSE_ERROR);
            continue;
        }

        ulong idle  = 0;
        ulong total = cpu_total_ticks(fields)!;

        idle = fields[4].to_ulong() ?? 0;
        if (fields.len > 5) idle += fields[5].to_ulong() ?? 0;

        cs.push({ .total = total, .idle = idle });
    }

    return cs.to_array(allocator);
}

fn void SystemCpuSnapshot[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void SystemCpuSnapshot.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

fn double cpu_percent(SystemCpuSnapshot old, SystemCpuSnapshot new) {
    if (new.total <= old.total || new.idle < old.idle) return 0.0;

    ulong total_delta = new.total - old.total;
    ulong idle_delta  = new.idle - old.idle;

    if ((idle_delta > total_delta) || (total_delta == 0)) return 0.0;

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

fn CpuCount? cpu_count() => @pool() {
    Path path        = path::new(tmem, "/sys/devices/system/cpu")!;
    PathList entries = io::path::ls(tmem, path)!;

    List{long} core_ids;
    core_ids.init(tmem);
    defer core_ids.free();

    int logical  = 0;
    int physical = 0;

    foreach (entry : entries) {
        String name = entry.file_tbasename()!;

        if (!name.starts_with("cpu")) continue;

        String suffix = name[3..];

        if (catch suffix.to_int()) continue;

        String online_path = string::tformat("/sys/devices/system/cpu/%s/online", name);

        File? online_file = file::open(online_path, "r");

        if (try File f = online_file) {
            defer (void)f.close();

            String value = linsys::read_file(f)!.trim();
            if (value == "0") continue;
        }

        logical++;

        String package_path = string::tformat(
            "/sys/devices/system/cpu/%s/topology/physical_package_id",
            name
        );

        String core_path = string::tformat("/sys/devices/system/cpu/%s/topology/core_id", name);

        File? package_file = file::open(package_path, "r");
        if (catch package_file) continue;
        defer (void)package_file.close();

        File? core_file = file::open(core_path, "r");
        if (catch core_file) continue;
        defer (void)core_file.close();

        long package_id = linsys::read_file(package_file)!.trim().to_long()!;
        long core_id    = linsys::read_file(core_file)!.trim().to_long()!;

        bool exists = false;

        foreach (i, existing_package : core_ids) {
            if (i % 2 != 0) continue;

            if (existing_package == package_id && core_ids[i + 1] == core_id) {
                exists = true;
                break;
            }
        }

        if (!exists) {
            core_ids.push(package_id);
            core_ids.push(core_id);
            physical++;
        }
    }

    return {
        .logical = logical,
        .physical = physical,
    };
}

fn void CpuFreq[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void CpuFreq.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

fn CpuFreq? cpu_freq() => @pool() {
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

    ulong current, minimum, maximum;

    linsys::@try_field(current, linsys::read_file(cur)!.trim().to_ulong(), "cpu_freq::current", 0);
    linsys::@try_field(minimum, linsys::read_file(min)!.trim().to_ulong(), "cpu_freq::min", 0);
    linsys::@try_field(maximum, linsys::read_file(max)!.trim().to_ulong(), "cpu_freq::max", 0);

    cf.current = (double)current / 1000.0;
    cf.min = (double)minimum / 1000.0;
    cf.max = (double)maximum / 1000.0;

    return cf;
}


fn CpuFreq[]? cpu_freq_percpu(Allocator allocator) => @pool() {
    Path path = path::new(tmem, "/sys/devices/system/cpu")!;

    PathList list = io::path::ls(tmem, path)!;

    List{CpuFreq} freqs;
    freqs.init(allocator);
    defer freqs.free();

    foreach (entry : list) {
        String name = entry.file_tbasename()!;

        if (!name.starts_with("cpu") || name == "cpufreq") continue;

        if (try name[3..].to_int()) {
            String base     = string::tformat("/sys/devices/system/cpu/%s/cpufreq", name);
            String cur_path = string::tformat("%s/scaling_cur_freq", base);
            String min_path = string::tformat("%s/scaling_min_freq", base);
            String max_path = string::tformat("%s/scaling_max_freq", base);
            ulong cur_val, min_val, max_val;



            {
                File? cur = file::open(cur_path, "r");
                if (catch cur) continue;
                defer (void)cur.close();

                linsys::@try_field(cur_val, linsys::read_file(cur)!.trim()
                    .to_ulong(), "cpufreq::current", 0);
            }



            {
                File? min = file::open(min_path, "r");
                if (catch min) continue;
                defer (void)min.close();
                linsys::@try_field(min_val, linsys::read_file(min)!.trim()
                    .to_ulong(), "cpufreq::min", 0);
            }



            {
                File? max = file::open(max_path, "r");
                if (catch max) continue;
                defer (void)max.close();
                linsys::@try_field(max_val, linsys::read_file(max)!.trim()
                    .to_ulong(), "cpufreq::max", 0);
            }

            freqs.push(
                { .current = cur_val / 1000.0, .min = min_val / 1000.0, .max = max_val / 1000.0 }
            );
        }
    }

    return freqs.to_array(allocator);
}

fn CpuStats? cpu_stats() => @pool() {
    File file = file::open("/proc/stat", "r")!;
    defer (void)file.close();
    CpuStats stats = { };

    while (try line = io::treadline(&file)) {
        String[] fields = linsys::split_whitespace(line);

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
                if (try ulong count = fields[1].to_ulong()) {
                    stats.syscalls.set(count);
                } else {
                    linsys::push_error("cpustats::syscalls", linsys::PARSE_ERROR);
                }
        }
    }

    return stats;
}


fn LoadAvg? load_avg() => @pool() {
    File file = file::open("/proc/loadavg", "r")!;
    defer (void)file.close();

    while (try line = io::treadline(&file)) {
        String[] fields = linsys::split_whitespace(line);

        if (fields.len < 3) {
            return linsys::PARSE_ERROR~;
        }

        double one, five, fifteen;
        linsys::@try_field(one, fields[0].to_double(), "loadavg::one", 0);
        linsys::@try_field(five, fields[1].to_double(), "loadavg::five", 0);
        linsys::@try_field(fifteen, fields[2].to_double(), "loadavg::fifteen", 0);
        return { .one = one, .five = five, .fifteen = fifteen };
    }
    return linsys::UNKNOWN~;
}

fn CpuInfo[]? cpu_info(Allocator allocator) => @pool() {
    File file = file::open("/proc/cpuinfo", "r")!;
    defer (void)file.close();

    List{CpuInfo} infos;
    infos.init(allocator);

    CpuInfo current  = { };
    bool transferred = false;

    defer {
        if (!transferred) {
            foreach (info : infos) {
                info.free(allocator);
            }

            current.free(allocator);
        }

        infos.free();
    }

    while (try line = io::treadline(&file)) {
        line = line.trim();

        if (line.len == 0) {
            if (current.vendor.len > 0 || current.model.len > 0 || current.flags.len > 0
                || current.cores > 0
                || current.siblings > 0
                || current.mhz > 0) {
                infos.push(current);
                current = { };
            }

            continue;
        }

        String[] split = line.split(tmem, ":");
        if (split.len < 2) continue;

        String key = split[0].trim();
        String val = split[1].trim();

        switch (key) {
            case "vendor_id":
            case "CPU implementer":
                if (current.vendor.len > 0) {
                    mem::alloc::free(allocator, current.vendor);
                }
                current.vendor = val.copy(allocator);

            case "model name":
            case "Processor":
            case "Hardware":
                if (current.model.len > 0) {
                    mem::alloc::free(allocator, current.model);
                }
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
            case "Features":
                if (current.flags.len > 0) {
                    mem::alloc::free(allocator, current.flags);
                }
                current.flags = val.copy(allocator);
        }
    }

    if (current.vendor.len > 0 || current.model.len > 0 || current.flags.len > 0
        || current.cores > 0
        || current.siblings > 0
        || current.mhz > 0) {
        infos.push(current);
        current = { };
    }

    CpuInfo[] output = infos.to_array(allocator);
    transferred = true;

    return output;
}

fn void CpuInfo[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void CpuInfo.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

fn ThermalZones[]? thermal_zones(Allocator allocator) => @pool() {
    Path path        = path::new(tmem, "/sys/class/thermal")!;
    PathList entries = io::path::ls(tmem, path)!;

    List{ThermalZones} temps;
    temps.init(allocator);

    bool transferred = false;

    defer {
        if (!transferred) {
            foreach (temp : temps) {
                temp.free(allocator);
            }
        }

        temps.free();
    }

    foreach (entry : entries) {
        @pool() {
            String name = entry.file_tbasename()!;

            if (!name.starts_with("thermal_zone")) continue;

            String base = string::tformat("/sys/class/thermal/%s", name);

            String temp_path = string::tformat("%s/temp", base);
            String type_path = string::tformat("%s/type", base);

            File? maybe_temp = file::open(temp_path, "r");

            if (catch err = maybe_temp) {
                linsys::push_error("thermal::temp", err);
                continue;
            }

            File tf = maybe_temp;
            defer (void)tf.close();

            File? maybe_type = file::open(type_path, "r");

            if (catch err = maybe_type) {
                linsys::push_error("thermal::type", err);
                continue;
            }

            File ty = maybe_type;
            defer (void)ty.close();

            String? maybe_temp_content = linsys::read_file(tf);

            if (catch err = maybe_temp_content) {
                linsys::push_error("thermal::temp", err);
                continue;
            }

            String? maybe_type_content = linsys::read_file(ty);

            if (catch err = maybe_type_content) {
                linsys::push_error("thermal::type", err);
                continue;
            }

            long? maybe_value = maybe_temp_content.trim().to_long();

            if (catch err = maybe_value) {
                linsys::push_error("thermal::temp", err);
                continue;
            }

            String type_name = maybe_type_content.trim();

            temps.push(
                {
                    .sensor = type_name.copy(allocator),
                    .current = (double)maybe_value / 1000.0,
                    .critical = 0.0,
                }
            );
        };
    }

    ThermalZones[] output = temps.to_array(allocator);
    transferred = true;

    return output;
}

fn void ThermalZones[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void ThermalZones.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

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
        String content  = linsys::read_file(file)!;
        String[] fields = linsys::split_whitespace(content.trim());
        if (fields.len < 1) return linsys::NOT_FOUND~;
        return fields[0].to_double();
    };
}

fn String? hostname(Allocator allocator) {
    File file = file::open("/proc/sys/kernel/hostname", "r")!;
    defer (void)file.close();
    return linsys::read_file(file)!.trim().copy(allocator);
}

fn String? kernel_version(Allocator allocator) {
    File file = file::open("/proc/sys/kernel/osrelease", "r")!;
    defer (void)file.close();
    return linsys::read_file(file)!.trim().copy(allocator);
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

fn ulong? boot_time() {
    return read_boot_time();
}

fn ulong? read_boot_time() @private {
    File file = file::open("/proc/stat", "r")!;
    defer (void)file.close();

    while (try line = io::treadline(&file)) {
        if (!line.starts_with("btime ")) continue;

        return line.strip_prefix("btime ").trim().to_ulong();
    }

    return linsys::PARSE_ERROR~;
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

struct Users {
    String name;
    String terminal;
    String host;
    long started;
    int pid;
}

struct Timeval {
    long tv_sec;
    long tv_usec;
}

struct Utmp {
    short type;
    int pid;
    char[32] line;
    char[4] id;
    char[32] user;
    char[256] host;
    int exit_status;
    int session;
    Timeval tv;
    int[4] addr_v6;
    char[20] reserved;
}

extern fn void setutent();
extern fn Utmp* getutent();
extern fn void endutent();

fn String? utmp_string(char* value, sz capacity, Allocator allocator) @private => @pool() {
    sz len = 0;

    while (len < capacity && value[len] != 0) {
        len++;
    }

    return ((String)value[..len]).copy(allocator);
}

fn Users[]? users(Allocator allocator) => @pool() {
    List{Users} result;
    result.init(allocator);
    bool transferred = false;

    defer {
        if (!transferred) {
            foreach (entry : result) {
                entry.free(allocator);
            }
        }

        result.free();
    }

    setutent();
    defer endutent();

    while (true) {
        Utmp* entry = getutent();
        if (entry == null) break;
        if (entry.type != 7) continue;

        Users user            = { };
        bool user_transferred = false;



        {
            defer if (!user_transferred) user.free(allocator);

            user.name = utmp_string(&entry.user, 32, allocator)!;

            user.terminal = utmp_string(&entry.line, 32, allocator)!;

            user.host = utmp_string(&entry.host, 256, allocator)!;

            user.started = (long)entry.tv.tv_sec;
            user.pid = entry.pid;

            result.push(user);
            user_transferred = true;
        }
    }

    Users[] output = result.to_array(allocator);
    transferred = true;

    return output;
}

fn void Users.free(self, Allocator allocator) {
    linsys::free_fields(self, allocator);
}

fn void Users[].free(self, Allocator allocator) {
    linsys::free_slice(self, allocator);
}

// Will need to split Cgroups, if it becomes fairly large
struct Cgroup {
    String path;
    String name;
    String[] controllers;
}

struct CgroupInfo {
    String path;

    ulong memory_current;
    ulong memory_max;

    ulong cpu_usage;
    ulong pids_current;
    ulong pids_max;
}

fn void? cgroup_walk(Allocator allocator, String path, List{Cgroup}* result) @private => @pool() {
    PathList entries = io::path::ls(tmem, (Path)path)!;

    foreach (entry : entries) {
        String child = string::tformat("%s/%s", path, entry);

        if (!path::is_dir((Path)child)) continue;

        String controllers_path = string::tformat("%s/cgroup.controllers", child);

        List{String} controllers;
        controllers.init(allocator);

        bool controllers_transferred = false;



        {
            defer {
                if (!controllers_transferred) {
                    foreach (controller : controllers) {
                        mem::alloc::free(allocator, controller);
                    }
                }

                controllers.free();
            }

            File? maybe_file = file::open(controllers_path, "r");

            if (try File f = maybe_file) {
                defer (void)f.close();

                if (try line = io::treadline(&f)) {
                    String[] fields = linsys::split_whitespace(line);

                    foreach (field : fields) {
                        controllers.push(field.copy(allocator));
                    }
                }
            }

            Cgroup group           = { };
            bool group_transferred = false;



            {
                defer if (!group_transferred) group.free(allocator);

                group.path = child.copy(allocator);

                sz? slash = child.rindex_of_char('/');

                if (catch slash) {
                    group.name = child.copy(allocator);
                } else {
                    group.name = child[slash + 1..].copy(allocator);
                }

                group.controllers = controllers.to_array(allocator);
                controllers_transferred = true;

                result.push(group);
                group_transferred = true;
            }
        }

        cgroup_walk(allocator, child, result)!;
    }
}

fn void Cgroup[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void Cgroup.free(self, Allocator allocator) {
    mem::alloc::free(allocator, self.path);
    mem::alloc::free(allocator, self.name);

    foreach (controller : self.controllers) {
        mem::alloc::free(allocator, controller);
    }

    mem::alloc::free(allocator, self.controllers);
}

fn Cgroup[]? cgroups(Allocator allocator) => @pool() {
    List{Cgroup} result;
    result.init(allocator);

    bool transferred = false;

    defer {
        if (!transferred) {
            foreach (group : result) {
                group.free(allocator);
            }
        }

        result.free();
    }

    cgroup_walk(allocator, "/sys/fs/cgroup", &result)!;

    Cgroup[] output = result.to_array(allocator);
    transferred = true;

    return output;
}

fn CgroupInfo? cgroup_info(Allocator allocator) @private => @pool() {
    abort("");
}
