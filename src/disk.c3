module linsys::disk;
import linsys @public;
import std::io;
import libc;
import std::collections::list;
import std::collections::map;
import std::thread;
import std::math;

struct DiskPartition {
    String device;
    String mountpoint;
    String filesystem;
    String options;
}

struct DiskUsage {
    ulong total;
    ulong used;
    ulong free;
    double percent;
}

fn String DiskUsage.total_human(self) => human_bytes(tmem, self.total);
fn String DiskUsage.used_human(self) => human_bytes(tmem, self.used);
fn String DiskUsage.free_human(self) => human_bytes(tmem, self.free);

struct HumanDiskUsage {
    String total;
    String used;
    String _free;
    double percent;
}

fn String human_bytes(Allocator allocator, ulong bytes) @private {
    const String[6] UNITS = { "B", "KiB", "MiB", "GiB", "TiB", "PiB" };

    double value = (double)bytes;
    int unit     = 0;

    while (value >= 1024.0 && unit < 5) {
        value /= 1024.0;
        unit++;
    }

    return string::format(allocator, "%.2f %s", value, UNITS[unit]);
}

fn void HumanDiskUsage.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

struct DiskIoCounters {
    String name;
    ulong read_count;
    ulong write_count;

    ulong read_merged_count;
    ulong write_merged_count;

    ulong read_bytes;
    ulong write_bytes;

    ulong read_time;
    ulong write_time;
    ulong busy_time;

    ulong weighted_io_time;

    ulong discard_count;
    ulong discard_merged_count;
    ulong discard_bytes;
    ulong discard_time;

    ulong flush_count;
    ulong flush_time;
}

struct Statvfs {
    ulong block_size;
    ulong fragment_size;
    ulong blocks;
    ulong blocks_free;
    ulong blocks_available;
    ulong files;
    ulong files_free;
    ulong files_available;
    ulong name_max;
}

extern fn int _statvfs(ZString path, Statvfs* buf) @private;

fn String unescape_mount_field(Allocator allocator, String input) @private {
    char[] output = mem::alloc::alloc_array(allocator, char, input.len);

    usz i = 0;
    usz j = 0;

    while (i < input.len) {
        if (input[i] == '\\' && i + 3 < input.len) {
            char a = input[i + 1];
            char b = input[i + 2];
            char c = input[i + 3];

            if (a >= '0' && a <= '7' && b >= '0' && b <= '7' && c >= '0' && c <= '7') {
                output[j++] = (char)(((a - '0') << 6) | ((b - '0') << 3) | (c - '0'));

                i += 4;
                continue;
            }
        }

        output[j++] = input[i++];
    }

    String result = ((String)output[:j]).copy(allocator);
    mem::alloc::free(allocator, output);

    return result;
}

struct DiskContext @deprecated {
    HashMap{String, ulong} sector_size_cache;
    Mutex cache_mutex;
    Allocator allocator;
}

fn bool is_pseudo_filesystem(String fs) @private {
    switch (fs) {
        case "proc":
        case "sysfs":
        case "devpts":
        case "devtmpfs":
        case "cgroup":
        case "cgroup2":
        case "securityfs":
        case "debugfs":
        case "tracefs":
        case "configfs":
        case "pstore":
        case "bpf":
        case "mqueue":
        case "hugetlbfs":
        case "fusectl":
        case "autofs":
        case "rpc_pipefs":
        case "binfmt_misc":
            return true;

        default:
            return false;
    }
}

fn DiskPartition[]? partitions(Allocator allocator, bool all = true) => @pool() {
    File file = file::open("/proc/mounts", "r")!;
    defer (void)file.close();

    List{DiskPartition} parts;
    parts.init(allocator);

    bool transferred = false;

    defer {
        if (!transferred) {
            foreach (part : parts) {
                part.free(allocator);
            }
        }
        parts.free();
    }

    while (try line = io::treadline(&file)) {
        if (line.len == 0) continue;

        String[] fields = linsys::split_whitespace(line);

        if (fields.len < 4) {
            linsys::push_error("diskpartition::line", linsys::PARSE_ERROR);
            continue;
        }

        if (!all && is_pseudo_filesystem(fields[2])) {
            continue;
        }

        parts.push(
            {
                .device = unescape_mount_field(allocator, fields[0]),
                .mountpoint = unescape_mount_field(allocator, fields[1]),
                .filesystem = unescape_mount_field(allocator, fields[2]),
                .options = unescape_mount_field(allocator, fields[3]),
            }
        );
    }

    DiskPartition[] output = parts.to_array(allocator);
    transferred = true;

    return output;
}

fn void DiskPartition[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void DiskPartition.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

<*
 @require path.len > 0 : "path must not be empty"
*>
fn DiskUsage? usage(String path) => @pool() {
    Statvfs svfs = { };

    if (_statvfs(path.zstr_tcopy(), &svfs) != 0) {
        return linsys::IO_ERROR~;
    }

    ulong block_size = svfs.fragment_size;

    ulong total = svfs.blocks * block_size;
    ulong free  = svfs.blocks_available * block_size;
    ulong used  = (svfs.blocks - svfs.blocks_free) * block_size;

    double usable = (double)used + (double)free;

    return {
        .total = total,
        .used = used,
        .free = free,
        .percent = usable > 0 ? (double)used / usable * 100.0 : 0.0,
    };
}

fn void DiskContext.init(&self, Allocator allocator) {
    self.allocator = allocator;
    self.sector_size_cache.init(allocator);

    if (catch err = self.cache_mutex.init()) {
        self.sector_size_cache.free();
        io::printfn("mutex init failed: %s", err);
        unreachable();
    }
}

fn void DiskContext.free(&self) {
    foreach (key : self.sector_size_cache.key_iter()) {
        mem::alloc::free(self.allocator, key);
    }

    self.sector_size_cache.free();
    self.cache_mutex.destroy();
}

fn ulong DiskContext.sector_size(&self, String device) => @pool() {
    self.cache_mutex.lock();

    if (try ulong size = self.sector_size_cache.get(device)) {
        self.cache_mutex.unlock();
        return size;
    }
    self.cache_mutex.unlock();

    String sector_path = string::tformat("/sys/block/%s/queue/physical_block_size", device);
    ulong size         = linsys::read_ulong_file(sector_path) ?? 512;
    self.cache_mutex.lock();
    defer self.cache_mutex.unlock();

    if (try ulong existing = self.sector_size_cache.get(device)) return existing;
    self.sector_size_cache.set(device, size);

    return size;
}

const int DISKSTATS_MIN_FIELDS = 14; // kernel 2.6+

fn DiskIoCounters? parse_line(Allocator allocator, String[] fields) @private {
    if (fields.len < DISKSTATS_MIN_FIELDS) return linsys::NOT_FOUND~;

    ulong rc  = 0;
    ulong rmc = 0;
    ulong rb  = 0;
    ulong rt  = 0;
    ulong wc  = 0;
    ulong wmc = 0;
    ulong wb  = 0;
    ulong wt  = 0;
    ulong bt  = 0;

    ulong weighted        = 0;
    ulong discard_count   = 0;
    ulong discard_merged  = 0;
    ulong discard_sectors = 0;
    ulong discard_time    = 0;
    ulong flush_count     = 0;
    ulong flush_time      = 0;

    linsys::@try_field(rc, fields[3].to_ulong(), "diskiocounters::read_count", 0);
    linsys::@try_field(rmc, fields[4].to_ulong(), "diskiocounters::read_merged_count", 0);
    linsys::@try_field(rb, fields[5].to_ulong(), "diskiocounters::read_sectors", 0);
    linsys::@try_field(rt, fields[6].to_ulong(), "diskiocounters::read_time", 0);

    linsys::@try_field(wc, fields[7].to_ulong(), "diskiocounters::write_count", 0);
    linsys::@try_field(wmc, fields[8].to_ulong(), "diskiocounters::write_merged_count", 0);
    linsys::@try_field(wb, fields[9].to_ulong(), "diskiocounters::write_sectors", 0);
    linsys::@try_field(wt, fields[10].to_ulong(), "diskiocounters::write_time", 0);

    linsys::@try_field(bt, fields[12].to_ulong(), "diskiocounters::busy_time", 0);
    linsys::@try_field(weighted, fields[13].to_ulong(), "diskiocounters::weighted_io_time", 0);

    if (fields.len >= 18) {
        linsys::@try_field(
            discard_count,
            fields[14].to_ulong(),
            "diskiocounters::discard_count",
            0
        );
        linsys::@try_field(
            discard_merged,
            fields[15].to_ulong(),
            "diskiocounters::discard_merged_count",
            0
        );
        linsys::@try_field(
            discard_sectors,
            fields[16].to_ulong(),
            "diskiocounters::discard_sectors",
            0
        );
        linsys::@try_field(discard_time, fields[17].to_ulong(), "diskiocounters::discard_time", 0);
    }

    if (fields.len >= 20) {
        linsys::@try_field(flush_count, fields[18].to_ulong(), "diskiocounters::flush_count", 0);
        linsys::@try_field(flush_time, fields[19].to_ulong(), "diskiocounters::flush_time", 0);
    }

    if (rb > ulong::max / 512) {
        linsys::push_error("diskiocounters::read_bytes", linsys::PARSE_ERROR);
        rb = 0;
    }

    if (wb > ulong::max / 512) {
        linsys::push_error("diskiocounters::write_bytes", linsys::PARSE_ERROR);
        wb = 0;
    }

    if (discard_sectors > ulong::max / 512) {
        linsys::push_error("diskiocounters::discard_bytes", linsys::PARSE_ERROR);
        discard_sectors = 0;
    }

    return {
        .name = fields[2].copy(allocator),
        .read_count = rc,
        .read_merged_count = rmc,
        .read_bytes = rb * 512,
        .read_time = rt,
        .write_count = wc,
        .write_merged_count = wmc,
        .write_bytes = wb * 512,
        .write_time = wt,
        .busy_time = bt,
        .weighted_io_time = weighted,
        .discard_count = discard_count,
        .discard_merged_count = discard_merged,
        .discard_bytes = discard_sectors * 512,
        .discard_time = discard_time,
        .flush_count = flush_count,
        .flush_time = flush_time,
    };
}

fn DiskIoCounters[]? io_counters(Allocator allocator) => @pool() {
    File file = file::open("/proc/diskstats", "r")!;
    defer (void)file.close();
    List{DiskIoCounters} disks;
    disks.init(allocator);
    bool transferred = false;

    defer {
        if (!transferred) {
            foreach (disk : disks) {
                disk.free(allocator);
            }
        }
        disks.free();
    }

    while (try line = io::treadline(&file)) {
        if (line.len == 0) continue;
        String[] fields = linsys::split_whitespace(line.trim());
        if (try disk = parse_line(allocator, fields)) {
            disks.push(disk);
        } else {
            linsys::push_error("diskiocounters::line", linsys::PARSE_ERROR);
        }
    }

    DiskIoCounters[] output = disks.to_array(allocator);
    transferred = true;
    return output;
}

fn void DiskIoCounters[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void DiskIoCounters.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

<*
 @require device.len > 0 : "device name must not be empty"
*>
fn DiskIoCounters? io_counters_perdisk(
    Allocator allocator,
    String device,
) => @pool() {
    File file = file::open("/proc/diskstats", "r")!;
    defer (void)file.close();

    while (try line = io::treadline(&file)) {
        if (line.len == 0) continue;
        String[] fields = linsys::split_whitespace(line.trim());
        if (fields.len < DISKSTATS_MIN_FIELDS) {
            linsys::push_error("diskiocounters::line", linsys::PARSE_ERROR);
            continue;
        }

        if (fields[2] != device) continue;
        return parse_line(allocator, fields);
    }
    return linsys::NOT_FOUND~;
}

struct DiskIoPoller {
    File file;
    List{DiskIoCounters} list;
    DiskIoCounters* current_disk;
    Allocator allocator;
}

fn DiskIoPoller? poller(Allocator allocator) {
    File file = file::open("/proc/diskstats", "r")!;

    List{DiskIoCounters} list;
    list.init(allocator);

    return {
        .file = file,
        .list = list,
        .allocator = allocator,
    };
}

fn void DiskIoPoller.close(&self) {
    (void)self.file.close();

    foreach (disk : self.list) {
        disk.free(self.allocator);
    }

    self.list.free();

    if (self.current_disk != null) {
        self.current_disk.free(self.allocator);
        mem::alloc::free(self.allocator, self.current_disk);
        self.current_disk = null;
    }
}

macro void? DiskIoPoller.@poll(&self; @body(dio)) => @pool() {
    List{DiskIoCounters} next;
    next.init(self.allocator);

    bool transferred = false;

    defer {
        if (!transferred) {
            foreach (disk : next) {
                disk.free(self.allocator);
            }
            next.free();
        }
    }

    self.file.seek(0, FROM_START)!;

    while (try line = io::treadline(&self.file)) {
        if (line.len == 0) continue;

        String[] fields = linsys::split_whitespace(line.trim());

        if (try disk = parse_line(self.allocator, fields)) {
            next.push(disk);
        } else {
            linsys::push_error("diskiopoller::line", linsys::PARSE_ERROR);
        }
    }

    List{DiskIoCounters} previous = self.list;
    self.list = next;
    transferred = true;

    foreach (disk : previous) {
        disk.free(self.allocator);
    }
    previous.free();

    @body(self.list.array_view());
}

<*
 @require device.len > 0 : "device name must not be empty"
*>
macro void? DiskIoPoller.@poll_perdisk(&self, String device; @body(dio)) => @pool() {
    self.file.seek(0, FROM_START)!;

    while (try line = io::treadline(&self.file)) {
        if (line.len == 0) continue;

        String[] fields = linsys::split_whitespace(line.trim());

        if (fields.len < DISKSTATS_MIN_FIELDS) {
            linsys::push_error("diskiopoller::line", linsys::PARSE_ERROR);
            continue;
        }

        if (fields[2] != device) continue;

        DiskIoCounters next         = parse_line(self.allocator, fields)!;
        DiskIoCounters* replacement = mem::alloc::new(self.allocator, DiskIoCounters);
        *replacement = next;

        DiskIoCounters* previous = self.current_disk;
        self.current_disk = replacement;

        if (previous != null) {
            previous.free(self.allocator);
            mem::alloc::free(self.allocator, previous);
        }

        @body(*self.current_disk);
        return;
    }

    return linsys::NOT_FOUND~;
}

struct DiskIoRates {
    double read_bytes_per_sec;
    double write_bytes_per_sec;
    double read_iops;
    double write_iops;
    double utilization_percent;
    double avg_read_latency_ms;
    double avg_write_latency_ms;
}

fn DiskIoRates io_rates(DiskIoCounters previous, DiskIoCounters current, double elapsed_seconds) {
    DiskIoRates rates = { };

    if (elapsed_seconds <= 0) return rates;

    ulong read_bytes  = 0;
    ulong write_bytes = 0;
    ulong reads       = 0;
    ulong writes      = 0;
    ulong busy_ms     = 0;
    ulong read_ms     = 0;
    ulong write_ms    = 0;

    if (previous.read_bytes && current.read_bytes) {
        linsys::@try_field(
            read_bytes,
            system::counter_delta(previous.read_bytes, current.read_bytes),
            "diskrates::read_bytes",
            0
        );
        rates.read_bytes_per_sec = (double)read_bytes / elapsed_seconds;
    }

    if (previous.write_bytes && current.write_bytes) {
        linsys::@try_field(
            write_bytes,
            system::counter_delta(previous.write_bytes, current.write_bytes),
            "diskrates::write_bytes",
            0
        );
        rates.write_bytes_per_sec = (double)write_bytes / elapsed_seconds;
    }

    if (previous.read_count && current.read_count) {
        linsys::@try_field(
            reads,
            system::counter_delta(previous.read_count, current.read_count),
            "diskrates::read_count",
            0
        );
        rates.read_iops = (double)reads / elapsed_seconds;
    }

    if (previous.write_count && current.write_count) {
        linsys::@try_field(
            writes,
            system::counter_delta(previous.write_count, current.write_count),
            "diskrates::write_count",
            0
        );
        rates.write_iops = (double)writes / elapsed_seconds;
    }

    if (previous.busy_time && current.busy_time) {
        linsys::@try_field(
            busy_ms,
            system::counter_delta(previous.busy_time, current.busy_time),
            "diskrates::busy_time",
            0
        );

        rates.utilization_percent = (double)busy_ms / (elapsed_seconds * 1000.0) * 100.0;
    }

    if (previous.read_time && current.read_time && previous.read_count && current.read_count) {
        linsys::@try_field(
            read_ms,
            system::counter_delta(previous.read_time, current.read_time),
            "diskrates::read_time",
            0
        );

        if (reads > 0) {
            rates.avg_read_latency_ms = (double)read_ms / (double)reads;
        }
    }

    if (previous.write_time && current.write_time && previous.write_count && current.write_count) {
        linsys::@try_field(
            write_ms,
            system::counter_delta(previous.write_time, current.write_time),
            "diskrates::write_time",
            0
        );

        if (writes > 0) {
            rates.avg_write_latency_ms = (double)write_ms / (double)writes;
        }
    }

    return rates;
}

fn double? io_utilization(DiskIoCounters previous, DiskIoCounters current, double elapsed_seconds) {
    if (elapsed_seconds <= 0.0) {
        return linsys::INVALID_ARGUMENT~;
    }

    if (current.busy_time < previous.busy_time) {
        return linsys::PARSE_ERROR~;
    }

    ulong busy_delta = current.busy_time - previous.busy_time;

    double percent = (double)busy_delta / (elapsed_seconds * 1000.0) * 100.0;

    return math::min(percent, 100.0);
}

struct DiskIoLatency {
    double read_ms;
    double write_ms;
}

fn DiskIoLatency io_latency(DiskIoCounters previous, DiskIoCounters current) {
    DiskIoLatency result = { };

    ulong reads      = 0;
    ulong writes     = 0;
    ulong read_time  = 0;
    ulong write_time = 0;

    linsys::@try_field(
        reads,
        system::counter_delta(previous.read_count, current.read_count),
        "disklatency::read_count",
        0
    );

    linsys::@try_field(
        writes,
        system::counter_delta(previous.write_count, current.write_count),
        "disklatency::write_count",
        0
    );

    linsys::@try_field(
        read_time,
        system::counter_delta(previous.read_time, current.read_time),
        "disklatency::read_time",
        0
    );

    linsys::@try_field(
        write_time,
        system::counter_delta(previous.write_time, current.write_time),
        "disklatency::write_time",
        0
    );

    result.read_ms = reads > 0 ? (double)read_time / (double)reads : 0.0;

    result.write_ms = writes > 0 ? (double)write_time / (double)writes : 0.0;

    return result;
}

struct DiskDeviceInfo {
    String name;
    String model;
    String vendor;
    bool rotational;
    ulong logical_block_size;
    ulong physical_block_size;
    ulong size;
}

fn String? read_disk_attribute(Allocator allocator, String path) @private => @pool() {
    File file = file::open(path, "r")!;
    defer (void)file.close();

    String line = io::treadline(&file)!;

    return line.trim().copy(allocator);
}

<*
 @require device.len > 0 : "device name must not be empty"
*>
fn DiskDeviceInfo device_info(Allocator allocator, String device) => @pool() {
    DiskDeviceInfo info = {
        .name = device.copy(allocator),
    };

    String base            = string::tformat("/sys/class/block/%s", device);
    String model_path      = string::tformat("%s/device/model", base);
    String vendor_path     = string::tformat("%s/device/vendor", base);
    String rotational_path = string::tformat("%s/queue/rotational", base);
    String logical_path    = string::tformat("%s/queue/logical_block_size", base);
    String physical_path   = string::tformat("%s/queue/physical_block_size", base);
    String size_path       = string::tformat("%s/size", base);

    info.model = "".copy(allocator);
    info.vendor = "".copy(allocator);

    if (try String value = read_disk_attribute(allocator, model_path)) {
        mem::alloc::free(allocator, info.model);
        info.model = value;
    } else {
        linsys::push_error("diskdevice::model", linsys::IO_ERROR);
    }

    if (try String value = read_disk_attribute(allocator, vendor_path)) {
        mem::alloc::free(allocator, info.vendor);
        info.vendor = value;
    } else {
        linsys::push_error("diskdevice::vendor", linsys::IO_ERROR);
    }

    ulong rotational = 0;
    ulong logical    = 0;
    ulong physical   = 0;
    ulong sectors    = 0;

    linsys::@try_field(
        rotational,
        linsys::read_ulong_file(rotational_path),
        "diskdevice::rotational",
        0
    );

    linsys::@try_field(
        logical,
        linsys::read_ulong_file(logical_path),
        "diskdevice::logical_block_size",
        0
    );

    linsys::@try_field(
        physical,
        linsys::read_ulong_file(physical_path),
        "diskdevice::physical_block_size",
        0
    );

    linsys::@try_field(sectors, linsys::read_ulong_file(size_path), "diskdevice::size", 0);

    info.rotational = rotational != 0;
    info.logical_block_size = logical;
    info.physical_block_size = physical;

    if (sectors <= ulong::max / 512) {
        info.size = sectors * 512;
    } else {
        linsys::push_error("diskdevice::size", linsys::PARSE_ERROR);
    }

    return info;
}

fn void DiskDeviceInfo.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

struct DiskInodeUsage {
    ulong total;
    ulong used;
    ulong free;
    double percent;
}

<*
 @require path.len > 0 : "path must not be empty"
*>
fn DiskInodeUsage? inode_usage(String path) => @pool() {
    Statvfs svfs = { };

    if (_statvfs(path.zstr_tcopy(), &svfs) != 0) {
        return linsys::IO_ERROR~;
    }

    ulong total = svfs.files;
    ulong free  = svfs.files_available;

    if (svfs.files_free > total) {
        return linsys::PARSE_ERROR~;
    }

    ulong used = total - svfs.files_free;

    double usable = (double)used + (double)free;

    return {
        .total = total,
        .used = used,
        .free = free,
        .percent = usable > 0 ? (double)used / usable * 100.0 : 0.0,
    };
}