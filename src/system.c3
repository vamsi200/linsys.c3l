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

extern fn CInt getpagesize() @private;

fn ulong? get_page_size() {
    CInt size = getpagesize();

    if (size <= 0) {
        return linsys::IO_ERROR~;
    }

    return (ulong)size;
}

fn ulong? counter_delta(ulong previous, ulong current) {
    if (current < previous) {
        return linsys::PARSE_ERROR~;
    }

    return current - previous;
}


fn SystemCpuTimes? parse_cpu_times(String line) @private {
    String[] fields = linsys::split_whitespace(line);

    if (fields.len < 5) {
        return linsys::PARSE_ERROR~;
    }

    SystemCpuTimes ct = { };

    ulong user       = 0;
    ulong nice       = 0;
    ulong system     = 0;
    ulong idle       = 0;
    ulong iowait     = 0;
    ulong irq        = 0;
    ulong softirq    = 0;
    ulong steal      = 0;
    ulong guest      = 0;
    ulong guest_nice = 0;

    if (fields.len > 1) linsys::@try_field(user, fields[1].to_ulong(), "cpu::user", 0);
    if (fields.len > 2) linsys::@try_field(nice, fields[2].to_ulong(), "cpu::nice", 0);
    if (fields.len > 3) linsys::@try_field(system, fields[3].to_ulong(), "cpu::system", 0);
    if (fields.len > 4) linsys::@try_field(idle, fields[4].to_ulong(), "cpu::idle", 0);
    if (fields.len > 5) linsys::@try_field(iowait, fields[5].to_ulong(), "cpu::iowait", 0);
    if (fields.len > 6) linsys::@try_field(irq, fields[6].to_ulong(), "cpu::irq", 0);
    if (fields.len > 7) linsys::@try_field(softirq, fields[7].to_ulong(), "cpu::softirq", 0);
    if (fields.len > 8) linsys::@try_field(steal, fields[8].to_ulong(), "cpu::steal", 0);
    if (fields.len > 9) linsys::@try_field(guest, fields[9].to_ulong(), "cpu::guest", 0);
    if (fields.len > 10) linsys::@try_field(
        guest_nice,
        fields[10].to_ulong(),
        "cpu::guest_nice",
        0
    );

    if (guest <= user) user -= guest;
    if (guest_nice <= nice) nice -= guest_nice;

    ulong hz = clktck();
    if (hz == 0) return linsys::PARSE_ERROR~;

    double scale = (double)hz;

    ct.user = (double)user / scale;
    ct.nice = (double)nice / scale;
    ct.system = (double)system / scale;
    ct.idle = (double)idle / scale;
    ct.iowait = (double)iowait / scale;
    ct.irq = (double)irq / scale;
    ct.softirq = (double)softirq / scale;
    ct.steal = (double)steal / scale;
    ct.guest = (double)guest / scale;
    ct.guest_nice = (double)guest_nice / scale;

    return ct;
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

    String line = io::treadline(&file)!;

    if (!line.starts_with("cpu ")) {
        return linsys::PARSE_ERROR~;
    }

    return parse_cpu_times(line);
}

fn SystemCpuTimes[]? cpu_times_percpu(Allocator allocator) => @pool() {
    File file = file::open("/proc/stat", "r")!;
    defer (void)file.close();

    List{SystemCpuTimes} cpus;
    cpus.init(allocator);
    defer cpus.free();

    while (try line = io::treadline(&file)) {
        if (!line.starts_with("cpu")) continue;
        if (line.starts_with("cpu ")) continue;

        String[] fields = linsys::split_whitespace(line);
        if (fields.len == 0 || fields[0].len <= 3) continue;

        if (catch fields[0][3..].to_int()) continue;

        if (try SystemCpuTimes ct = parse_cpu_times(line)) {
            cpus.push(ct);
        } else {
            linsys::push_error("cpu_times_percpu::line", linsys::PARSE_ERROR);
        }
    }

    return cpus.to_array(allocator);
}

fn void SystemCpuTimes[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void SystemCpuTimes.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

fn SystemCpuSnapshot? cpu_snapshot() => @pool() {
    File file = file::open("/proc/stat", "r")!;
    defer (void)file.close();
    String line = io::treadline(&file)!;
    if (!line.starts_with("cpu ")) return linsys::PARSE_ERROR~;
    String[] fields = linsys::split_whitespace(line);
    ulong total     = cpu_total_ticks(fields)!;
    ulong idle      = fields[4].to_ulong()!;

    if (fields.len > 5) {
        ulong wait = fields[5].to_ulong()!;
        if (wait > ulong::max - idle) return linsys::PARSE_ERROR~;
        idle += wait;
    }
    return { .total = total, .idle = idle };
}

fn ulong? cpu_total_ticks(String[] fields) @private {
    if (fields.len < 5) {
        return linsys::PARSE_ERROR~;
    }

    ulong total = 0;

    for (usz i = 1; i < fields.len && i <= 8; i++) {
        ulong value = fields[i].to_ulong()!;

        if (value > ulong::max - total) {
            return linsys::PARSE_ERROR~;
        }

        total += value;
    }

    return total;
}

fn SystemCpuSnapshot[]? cpu_snapshot_percpu(Allocator allocator) => @pool() {
    File file = file::open("/proc/stat", "r")!;
    defer (void)file.close();
    List{SystemCpuSnapshot} snapshots;
    snapshots.init(allocator);
    defer snapshots.free();
    while (try line = io::treadline(&file)) {
        if (!line.starts_with("cpu") || line.starts_with("cpu ")) continue;
        String[] fields = linsys::split_whitespace(line);
        if (fields.len < 5 || fields[0].len <= 3) continue;
        if (catch fields[0][3..].to_int()) continue;
        ulong? total = cpu_total_ticks(fields);
        if (catch total) {
            linsys::push_error("cpu_snapshot::total", linsys::PARSE_ERROR);
            continue;
        }
        ulong idle = fields[4].to_ulong() ?? 0;
        if (fields.len > 5) {
            ulong wait = fields[5].to_ulong() ?? 0;
            if (wait > ulong::max - idle) continue;
            idle += wait;
        }
        snapshots.push({ .total = total, .idle = idle });
    }
    return snapshots.to_array(allocator);
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

    foreach (i, previous : old) {
        out[i] = cpu_percent(previous, new[i]);
    }

    return out;
}

struct CpuCoreId @private {
    long package_id;
    long core_id;
}

fn CpuCount? cpu_count() => @pool() {
    Path path        = path::new(tmem, "/sys/devices/system/cpu")!;
    PathList entries = io::path::ls(tmem, path)!;
    List{CpuCoreId} ids;
    ids.init(tmem);
    defer ids.free();
    CpuCount count = { };

    foreach (entry : entries) {
        @pool() {
            String name = entry.file_tbasename()!;
            if (!name.starts_with("cpu")) continue;
            if (catch name[3..].to_int()) continue;
            String base = string::tformat("/sys/devices/system/cpu/%s", name);
            if (try ulong online = linsys::read_ulong_file(string::tformat("%s/online", base))) {
                if (online == 0) continue;
            }
            count.logical++;
            long package_id, core_id;

            bool found_package = false;
            bool found_core    = false;
            if (try ulong v = linsys::read_ulong_file(
                string::tformat("%s/topology/physical_package_id", base)
            )) {
                package_id = (long)v;
                found_package = true;
            }
            if (try ulong v = linsys::read_ulong_file(
                string::tformat("%s/topology/core_id", base)
            )) {
                core_id = (long)v;
                found_core = true;
            }
            if (!found_package || !found_core) continue;
            bool exists = false;
            foreach (id : ids) {
                if (id.package_id == package_id && id.core_id == core_id) {
                    exists = true;
                    break;
                }
            }
            if (!exists) {
                ids.push({ .package_id = package_id, .core_id = core_id });
                count.physical++;
            }
        };
    }
    return count;
}

fn void CpuFreq[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void CpuFreq.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

fn CpuFreq? cpu_freq() => @pool() {
    CpuFreq cf = { };

    String base     = "/sys/devices/system/cpu/cpu0/cpufreq";
    String cur_path = string::tformat("%s/scaling_cur_freq", base);
    String min_path = string::tformat("%s/scaling_min_freq", base);
    String max_path = string::tformat("%s/scaling_max_freq", base);

    ulong current = 0;
    ulong minimum = 0;
    ulong maximum = 0;

    linsys::@try_field(current, linsys::read_ulong_file(cur_path), "cpu_freq::current", 0);
    linsys::@try_field(minimum, linsys::read_ulong_file(min_path), "cpu_freq::min", 0);
    linsys::@try_field(maximum, linsys::read_ulong_file(max_path), "cpu_freq::max", 0);

    cf.current = (double)current / 1000.0;
    cf.min = (double)minimum / 1000.0;
    cf.max = (double)maximum / 1000.0;

    return cf;
}

fn CpuFreq[]? cpu_freq_percpu(Allocator allocator) => @pool() {
    Path path        = path::new(tmem, "/sys/devices/system/cpu")!;
    PathList entries = io::path::ls(tmem, path)!;
    List{CpuFreq} freqs;
    freqs.init(allocator);
    defer freqs.free();

    foreach (entry : entries) {
        @pool() {
            String name = entry.file_tbasename()!;
            if (!name.starts_with("cpu")) continue;
            if (catch name[3..].to_int()) continue;

            String base = string::tformat("/sys/devices/system/cpu/%s/cpufreq", name);
            ulong cur, min, max;
            linsys::@try_field(
                cur,
                linsys::read_ulong_file(string::tformat("%s/scaling_cur_freq", base)),
                "cpufreq::current",
                0
            );
            linsys::@try_field(
                min,
                linsys::read_ulong_file(string::tformat("%s/scaling_min_freq", base)),
                "cpufreq::min",
                0
            );
            linsys::@try_field(
                max,
                linsys::read_ulong_file(string::tformat("%s/scaling_max_freq", base)),
                "cpufreq::max",
                0
            );
            freqs.push(
                {
                    .current = (double)cur / 1000.0,
                    .min = (double)min / 1000.0,
                    .max = (double)max / 1000.0
                }
            );
        };
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
fn void CpuInfo.free(self, Allocator allocator) {
    if (self.vendor.len > 0) mem::alloc::free(allocator, self.vendor);
    if (self.model.len > 0) mem::alloc::free(allocator, self.model);
    if (self.flags.len > 0) mem::alloc::free(allocator, self.flags);
}

fn double thermal_critical(String base) @private => @pool() {
    for (int i = 0; i < 32; i++) {
        String type_path = string::tformat("%s/trip_point_%d_type", base, i);

        File? maybe_file = file::open(type_path, "r");
        if (catch maybe_file) continue;

        File f      = maybe_file;
        String type = "";

        if (try String line = io::treadline(&f)) {
            type = line.trim();
        }

        (void)f.close();

        if (type != "critical") continue;

        String temp_path = string::tformat("%s/trip_point_%d_temp", base, i);

        if (try ulong raw = linsys::read_ulong_file(temp_path)) {
            return (double)raw / 1000.0;
        }
    }

    return 0.0;
}

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
                    .critical = thermal_critical(base),
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
    CpuUsage usage = { };

    double old_total = old.user + old.nice + old.system + old.idle + old.iowait + old.irq
        + old.softirq
        + old.steal;

    double new_total = new.user + new.nice + new.system + new.idle + new.iowait + new.irq
        + new.softirq
        + new.steal;

    double delta = new_total - old_total;

    if (delta <= 0.0) return usage;

    double user   = new.user - old.user;
    double system = new.system - old.system;
    double idle   = new.idle - old.idle;
    double iowait = new.iowait - old.iowait;

    if (user < 0 || system < 0 || idle < 0 || iowait < 0) {
        return usage;
    }

    usage.user_percent = user / delta * 100.0;
    usage.system_percent = system / delta * 100.0;
    usage.idle_percent = idle / delta * 100.0;
    usage.iowait_percent = iowait / delta * 100.0;

    return usage;
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

fn String? hostname(Allocator allocator) => @pool() {
    File file = file::open("/proc/sys/kernel/hostname", "r")!;
    defer (void)file.close();
    return linsys::read_file(file)!.trim().copy(allocator);
}

fn String? kernel_version(Allocator allocator) => @pool() {
    File file = file::open("/proc/sys/kernel/osrelease", "r")!;
    defer (void)file.close();
    return linsys::read_file(file)!.trim().copy(allocator);
}

fn String? os_release(Allocator allocator) => @pool() {
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
    return read_clktck() ?? 100;
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

        if (type == 17 && val > 0) return val; // AT_CLKTCK
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
        String child = string::tformat("%s/%s", path, entry.file_tbasename()!);

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
    return linsys::UNKNOWN~;
}
