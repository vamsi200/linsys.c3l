module linsys::disk;
import linsys @public;
import std::io;
import libc;
import std::collections::list;
import std::collections::map;
import std::thread;

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
}

struct Statvfs {
    ulong f_bsize;
    ulong f_frsize;
    ulong f_blocks;
    ulong f_bfree;
    ulong f_bavail;
    ulong f_files;
    ulong f_ffree;
    ulong f_favail;
    ulong f_fsid;
    ulong f_flag;
    ulong f_namemax;

    char[128] __f_spare; // enough headroom I guess
}

extern fn int statvfs(ZString path, Statvfs* buf) @private;

struct DiskContext {
    HashMap{String, ulong} sector_size_cache;
    Mutex cache_mutex;
    Allocator allocator;
}

fn DiskPartition[]? partitions(Allocator allocator) => @pool() {
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
        if (line.len == 0) {
            continue;
        }

        String[] fields = linsys::split_whitespace(line);
        if (fields.len < 4) {
            linsys::push_error("diskpartition::line", linsys::PARSE_ERROR);
            continue;
        }

        parts.push(
            {
                .device = fields[0].copy(allocator),
                .mountpoint = fields[1].copy(allocator),
                .filesystem = fields[2].copy(allocator),
                .options = fields[3].copy(allocator),
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

    if (statvfs(path.zstr_tcopy(), &svfs) != 0) {
        return linsys::IO_ERROR~;
    }

    ulong block_size = svfs.f_frsize;
    ulong total      = svfs.f_blocks * block_size;
    ulong free       = svfs.f_bavail * block_size;
    ulong used       = (svfs.f_blocks - svfs.f_bfree) * block_size;

    ulong usable = used + free;

    double percent = usable > 0 ? (double)used / (double)usable * 100.0 : 0.0;

    return {
        .total = total,
        .used = used,
        .free = free,
        .percent = percent,
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
        io::printfn("Freed: %p", key.ptr);
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

    linsys::@try_field(rc, fields[3].to_ulong(), "diskiocounters::read_count", 0);
    linsys::@try_field(rmc, fields[4].to_ulong(), "diskiocounters::read_merged_count", 0);
    linsys::@try_field(rb, fields[5].to_ulong(), "diskiocounters::read_bytes", 0);
    linsys::@try_field(rt, fields[6].to_ulong(), "diskiocounters::read_time", 0);
    linsys::@try_field(wc, fields[7].to_ulong(), "diskiocounters::write_count", 0);
    linsys::@try_field(wmc, fields[8].to_ulong(), "diskiocounters::write_merged_count", 0);
    linsys::@try_field(wb, fields[9].to_ulong(), "diskiocounters::write_bytes", 0);
    linsys::@try_field(wt, fields[10].to_ulong(), "diskiocounters::write_time", 0);
    linsys::@try_field(bt, fields[12].to_ulong(), "diskiocounters::busy_time", 0);

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
    };
}

fn DiskIoCounters[]? io_counters(Allocator allocator, DiskContext* ctx) => @pool() {
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
    DiskContext* ctx
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
    DiskContext* ctx;
    List{DiskIoCounters} list;
    Allocator allocator;
}

fn DiskIoPoller? poller(Allocator allocator, DiskContext* ctx) {
    File file = file::open("/proc/diskstats", "r")!;

    List{DiskIoCounters} list;
    list.init(allocator);

    return {
        .file = file,
        .ctx = ctx,
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
}

macro void? DiskIoPoller.@poll(&self; @body(dio)) => @pool() {
    foreach (disk : self.list) {
        disk.free(self.allocator);
    }
    self.list.clear();

    self.file.seek(0, FROM_START)!;

    while (try line = io::treadline(&self.file)) {
        if (line.len == 0) continue;

        String[] fields = linsys::split_whitespace(line.trim());

        if (try disk = parse_line(self.allocator, fields)) {
            self.list.push(disk);
        } else {
            linsys::push_error("diskiopoller::line", linsys::PARSE_ERROR);
        }
    }

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

        if (fields.len < DISKSTATS_MIN_FIELDS) continue;
        if (fields[2] != device) continue;

        if (try dio = parse_line(tmem, fields)) {
            @body(dio);
            return;
        }

        linsys::push_error("diskiopoller::line", linsys::PARSE_ERROR);
        return linsys::PARSE_ERROR~;
    }

    return linsys::NOT_FOUND~;
}
