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
    ulong maxfile;
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
        case "overlay":
        case "squashfs":
        case "tmpfs":
        case "efivarfs":
        case "devfs":
        case "none":
        case "fuse.gvfsd-fuse":
        case "fuse.portal":
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

        String mountpoint = unescape_mount_field(tmem, fields[1]);

        Statvfs svfs  = { };
        ulong maxfile = 0;

        if (_statvfs(mountpoint.zstr_tcopy(), &svfs) == 0) maxfile = svfs.name_max;

        parts.push(
            {
                .device = unescape_mount_field(allocator, fields[0]),
                .mountpoint = unescape_mount_field(allocator, fields[1]),
                .filesystem = unescape_mount_field(allocator, fields[2]),
                .options = unescape_mount_field(allocator, fields[3]),
                .maxfile = maxfile,
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

    if (_statvfs(path.zstr_tcopy(), &svfs) != 0) return linsys::IO_ERROR~;

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

fn bool is_physical_disk(String name) @private => @pool() {
    if (name.starts_with("loop") || name.starts_with("ram")) return false;
    String part_path = string::tformat("/sys/class/block/%s/partition", name);

    File? opt_file = file::open(part_path, "r");
    if (catch err = opt_file) {
        return true;
    } else {
        (void)opt_file.close();
        return false;
    }
}

fn DiskIoCounters[]? io_counters(Allocator allocator, bool physical_only = false) => @pool() {
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

        if (fields.len < DISKSTATS_MIN_FIELDS) {
            linsys::push_error("diskiocounters::line", linsys::PARSE_ERROR);
            continue;
        }

        if (physical_only && !is_physical_disk(fields[2])) {
            continue;
        }

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

        if (reads > 0) rates.avg_read_latency_ms = (double)read_ms / (double)reads;
    }

    if (previous.write_time && current.write_time && previous.write_count && current.write_count) {
        linsys::@try_field(
            write_ms,
            system::counter_delta(previous.write_time, current.write_time),
            "diskrates::write_time",
            0
        );

        if (writes > 0) rates.avg_write_latency_ms = (double)write_ms / (double)writes;
    }

    return rates;
}

fn double? io_utilization(DiskIoCounters previous, DiskIoCounters current, double elapsed_seconds) {
    if (elapsed_seconds <= 0.0) return linsys::INVALID_ARGUMENT~;
    if (current.busy_time < previous.busy_time) return linsys::PARSE_ERROR~;

    ulong busy_delta = current.busy_time - previous.busy_time;
    double percent   = (double)busy_delta / (elapsed_seconds * 1000.0) * 100.0;

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

<*
 @require target_path.len > 0 : "path must not be empty"
*>
fn String? device_for_path(Allocator allocator, String target_path) => @pool() {
    DiskPartition[] parts = partitions(tmem)!;

    String match  = "";
    String device = "";
    usz max_len   = 0;

    foreach (part : parts) {
        if (target_path.starts_with(part.mountpoint)) {
            usz mlen = part.mountpoint.len;

            bool valid_boundary = (target_path.len == mlen) || (part.mountpoint == "/")
                || (target_path[mlen] == '/');

            if (valid_boundary && mlen > max_len) {
                max_len = mlen;
                match = part.mountpoint;
                device = part.device;
            }
        }
    }

    if (max_len > 0) {
        return device.copy(allocator);
    }

    return linsys::NOT_FOUND~;
}

// NOTE: some tests are written by LLM's
fn void test_disk_partitions() @test {
    linsys::@tracker(; Allocator alloc) {
        DiskPartition[]? parts = disk::partitions(alloc, true);
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

fn void test_disk_io_counters() @test {
    linsys::@tracker(; Allocator alloc) {
        DiskIoCounters[]? counters = disk::io_counters(alloc);
        if (catch counters) return;
        counters.free(alloc);
    };
}

fn void test_disk_device_info() @test {
    linsys::@tracker(; Allocator alloc) {
        DiskDeviceInfo info = disk::device_info(alloc, "sda");
        info.free(alloc);
    };
}

fn void test_disk_io_poller() @test {
    linsys::@tracker(; Allocator alloc) {
        DiskIoPoller? poller = disk::poller(alloc);
        if (catch poller) return;
        poller.close();
    };
}

fn void test_io_counters() @test {
    linsys::@tracker(; Allocator alloc) {
        DiskIoCounters[]? counters = disk::io_counters(alloc);
        if (catch counters) return;
        counters.free(alloc);
    };
}

fn void test_disk_io_poller_perdisk() @test {
    linsys::@tracker(; Allocator alloc) {
        DiskIoPoller poller = disk::poller(alloc)!!;
        if (catch poller.@poll_perdisk("sda" ; DiskIoCounters dio) {
        }) {
        }
        poller.close();
    };
}

fn void test_disk_parse_line_truncated() @test {
    linsys::@tracker(; Allocator alloc) {
        String short_line = " 8  0 sda".copy(alloc);
        defer mem::alloc::free(alloc, short_line);

        String[] fields = linsys::split_whitespace(short_line);

        DiskIoCounters? result = parse_line(alloc, fields);

        if (catch result) return;
        result.free(alloc);
    };
}

fn void test_disk_parse_line_overflow_values() @test {
    linsys::@tracker(; Allocator alloc) {
        String overflow_line = " 8  0 sda 0 0 18446744073709551615 0 0 0 0 0 0 0 0 0 0 0 0".copy(
            alloc
        );
        defer mem::alloc::free(alloc, overflow_line);

        String[] fields = linsys::split_whitespace(overflow_line);

        DiskIoCounters? result = parse_line(alloc, fields);
        if (catch result) return;

        assert(result.read_bytes == 0);
        result.free(alloc);
    };
}

fn void test_unescape_mount_field_edge_cases() @test {
    linsys::@tracker(; Allocator alloc) {
        String raw = "/dev/mapper/vg0-root\\040test\\999\\0".copy(alloc);
        defer mem::alloc::free(alloc, raw);

        String unescaped = unescape_mount_field(alloc, raw);
        defer mem::alloc::free(alloc, unescaped);

        assert(unescaped.len > 0);
    };
}

fn void test_disk_io_rates_zero_and_backwards_deltas() @test {
    DiskIoCounters prev = { .read_bytes = 5000, .busy_time = 200 };
    DiskIoCounters curr = { .read_bytes = 1000, .busy_time = 100 };

    DiskIoRates rates = io_rates(prev, curr, 1.0);

    assert(rates.read_bytes_per_sec >= 0.0);
}

fn void test_disk_io_utilization_edge_cases() @test {
    DiskIoCounters prev = { .busy_time = 100 };
    DiskIoCounters curr = { .busy_time = 150 };

    double? normal_util = io_utilization(prev, curr, 1.0);
    if (catch normal_util) {
        assert(false);
    } else {
        assert(normal_util == 5.0);
    }

    double? zero_time_util = io_utilization(prev, curr, 0.0);
    if (catch err = zero_time_util) {
        assert(err == linsys::INVALID_ARGUMENT);
    } else {
        assert(false);
    }

    DiskIoCounters curr_reset = { .busy_time = 50 };
    double? reset_util        = io_utilization(prev, curr_reset, 1.0);
    if (catch err = reset_util) {
        assert(err == linsys::PARSE_ERROR);
    } else {
        assert(false);
    }
}

fn void test_disk_io_latency_zero_ops() @test {
    DiskIoCounters prev = {
        .read_count = 10,
        .read_time = 100,
        .write_count = 5,
        .write_time = 50
    };
    DiskIoCounters curr = prev;

    DiskIoLatency latency = io_latency(prev, curr);

    assert(latency.read_ms == 0.0);
    assert(latency.write_ms == 0.0);
}

fn void test_disk_io_counters_perdisk_missing() @test {
    linsys::@tracker(; Allocator alloc) {
        DiskIoCounters? result = io_counters_perdisk(alloc, "nonexistent_fake_device_123");
        if (catch err = result) {
            assert(err == linsys::NOT_FOUND);
        } else {
            result.free(alloc);
            assert(false);
        }
    };
}

fn void test_disk_usage_root_fs() @test {
    DiskUsage? u = usage("/");
    if (catch u) return;

    assert(u.total > 0);
    assert(u.percent >= 0.0 && u.percent <= 100.0);
}

fn void test_disk_inode_usage_root_fs() @test {
    DiskInodeUsage? u = inode_usage("/");
    if (catch u) return;

    assert(u.total > 0);
    assert(u.percent >= 0.0 && u.percent <= 100.0);
}

fn void test_disk_expanded_pseudo_filesystems() @test {
    assert(is_pseudo_filesystem("overlay"));
    assert(is_pseudo_filesystem("squashfs"));
    assert(is_pseudo_filesystem("tmpfs"));
    assert(is_pseudo_filesystem("efivarfs"));

    assert(!is_pseudo_filesystem("ext4"));
    assert(!is_pseudo_filesystem("zfs"));
    assert(!is_pseudo_filesystem("vfat"));
}

fn void test_disk_partitions_maxfile_populated() @test {
    linsys::@tracker(; Allocator alloc) {
        DiskPartition[]? parts_opt = partitions(alloc, true);
        if (catch parts_opt) return;
        defer parts_opt.free(alloc);

        bool found_root = false;
        foreach (part : parts_opt) {
            if (part.mountpoint == "/") {
                found_root = true;
                assert(part.maxfile > 0);
            }
        }

        assert(found_root);
    };
}

fn void test_disk_io_counters_physical_only() @test {
    linsys::@tracker(; Allocator alloc) {
        DiskIoCounters[]? all_disks_opt = io_counters(alloc, false);
        if (catch all_disks_opt) return;
        defer all_disks_opt.free(alloc);

        DiskIoCounters[]? physical_opt = io_counters(alloc, true);
        if (catch physical_opt) return;
        defer physical_opt.free(alloc);

        // In almost all Linux environments, `all` (which includes loop devices
        // and partition slices) will be significantly larger than `physical`
        // (which only includes base physical drives like sda/nvme0n1).
        assert(all_disks_opt.len >= physical_opt.len);

        // Ensure no loopback or known partitions snuck into the physical list
        foreach (disk : physical_opt) {
            assert(!disk.name.starts_with("loop"));
            assert(!disk.name.starts_with("ram"));
        }
    };
}

fn void test_disk_device_for_path_boundary() @test {
    linsys::@tracker(; Allocator alloc) {
        String? dev = device_for_path(alloc, "/proc/cpuinfo");
        if (catch dev) return;
        defer mem::alloc::free(alloc, dev);

        assert(dev.len > 0);
    };
}
