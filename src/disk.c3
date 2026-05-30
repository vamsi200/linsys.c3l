module linsys;
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

extern fn int statvfs(ZString path, Statvfs* buf);

struct DiskContext {
    HashMap{String, ulong} sector_size_cache;
    Mutex cache_mutex;
    Allocator allocator;
}

fn DiskPartition[]? disk_partitions(Allocator allocator) {
    @pool() {
        File file = file::open("/proc/mounts", "r")!;
        defer (void)file.close();

        String content = read_file(tmem, file)!;

        List{DiskPartition} parts;
        parts.init(allocator);

        foreach (line : content.split(tmem, "\n")) {
            if (line.len == 0) {
                continue;
            }

            String[] fields = split_whitespace(tmem, line);

            if (fields.len < 4) {
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

        return parts.to_array(allocator);
    };
}

<*
 @require path.len > 0 : "path must not be empty"
*>
fn DiskUsage? disk_usage(String path) {
    Statvfs svfs = { };

    if (statvfs((ZString)path, &svfs) != 0) {
        return IO_ERROR~;
    }

    ulong total = svfs.f_blocks * svfs.f_frsize;

    ulong free = svfs.f_bavail * svfs.f_frsize;

    ulong used = total - free;

    double percent = 0.0;

    if (total > 0) {
        percent = ((double)used / (double)total) * 100.0;
    }

    return { .total = total, .used = used, .free = free, .percent = percent, };
}

fn void DiskContext.init(&self, Allocator allocator) {
    self.allocator = allocator;
    self.sector_size_cache.init(allocator);
    if (catch err = self.cache_mutex.init()) {
        io::printfn("mutex init failed: %s", err);
        unreachable();
    }
}

fn void DiskContext.free(&self) {
    self.sector_size_cache.free();
    self.cache_mutex.destroy();
}

fn ulong DiskContext.get_sector_size(&self, String device) {
    self.cache_mutex.lock();
    if (try ulong size = self.sector_size_cache.get(device)) {
        self.cache_mutex.unlock();
        return size;
    }
    self.cache_mutex.unlock();

    @pool() {
        String sector_path = string::tformat("/sys/block/%s/queue/physical_block_size", device);
        ulong size         = read_ulong_file(sector_path) ?? 512;

        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();
        if (try ulong existing = self.sector_size_cache.get(device)) return existing;
        self.sector_size_cache.set(device.copy(self.allocator), size);
        return size;
    };
}

const int DISKSTATS_MIN_FIELDS = 14; // kernel 2.6+

fn DiskIoCounters? parse_disk_line(Allocator allocator, String[] fields, DiskContext* ctx) @private {
    if (fields.len < DISKSTATS_MIN_FIELDS) return NOT_FOUND~;
    ulong sector_size = ctx.get_sector_size(fields[2]);
    return {
        .name = fields[2].copy(allocator),
        .read_count = fields[3].to_ulong() ?? 0,
        .read_merged_count = fields[4].to_ulong() ?? 0,
        .read_bytes = (fields[5].to_ulong() ?? 0) * sector_size,
        .read_time = fields[6].to_ulong() ?? 0,
        .write_count = fields[7].to_ulong() ?? 0,
        .write_merged_count = fields[8].to_ulong() ?? 0,
        .write_bytes = (fields[9].to_ulong() ?? 0) * sector_size,
        .write_time = fields[10].to_ulong() ?? 0,
        .busy_time = fields[12].to_ulong() ?? 0,
    };
}

fn DiskIoCounters[]? disk_io_counters(Allocator allocator, DiskContext* ctx) {
    @pool() {
        File file = file::open("/proc/diskstats", "r")!;
        defer (void)file.close();
        List{DiskIoCounters} disks;
        disks.init(allocator);
        while (try line = io::treadline(&file)) {
            if (line.len == 0) continue;
            String[] fields = split_whitespace(tmem, line.trim());
            if (try disk = parse_disk_line(allocator, fields, ctx)) {
                disks.push(disk);
            }
        }
        return disks.to_array(allocator);
    };
}

<*
 @require device.len > 0 : "device name must not be empty"
*>
fn DiskIoCounters? disk_io_counters_perdisk(Allocator allocator, String device, DiskContext* ctx) {
    @pool() {
        File file = file::open("/proc/diskstats", "r")!;
        defer (void)file.close();
        while (try line = io::treadline(&file)) {
            if (line.len == 0) continue;
            String[] fields = split_whitespace(tmem, line.trim());
            if (fields.len < DISKSTATS_MIN_FIELDS) continue;
            if (fields[2] != device) continue;
            return parse_disk_line(allocator, fields, ctx);
        }
    };
    return NOT_FOUND~;
}

struct DiskIoPoller {
    File file;
    DiskContext* ctx;
    List{DiskIoCounters} list;
    Allocator allocator;
}

fn DiskIoPoller? disk_io_poller_new(Allocator allocator, DiskContext* ctx) {
    List{DiskIoCounters} list;
    list.init(allocator);
    return { .file = file::open("/proc/diskstats", "r")!, .ctx = ctx, .list = list, .allocator = allocator, };
}

fn void DiskIoPoller.close(&self) {
    (void)self.file.close();
    self.list.free();
}

fn DiskIoCounters[]? DiskIoPoller.poll(&self) {
    @pool() {
        self.file.seek(0, FROM_START)!;
        self.list.clear();
        while (try line = io::treadline(&self.file)) {
            if (line.len == 0) continue;
            String[] fields = split_whitespace(tmem, line.trim());
            if (try disk = parse_disk_line(self.allocator, fields, self.ctx)) {
                self.list.push(disk);
            }
        }
        return self.list.array_view();
    };
}

<*
 @require device.len > 0 : "device name must not be empty"
*>
fn DiskIoCounters? DiskIoPoller.poll_perdisk(&self, String device) {
    @pool() {
        self.file.seek(0, FROM_START)!;
        while (try line = io::treadline(&self.file)) {
            if (line.len == 0) continue;
            String[] fields = split_whitespace(tmem, line.trim());
            if (fields.len < DISKSTATS_MIN_FIELDS) continue;
            if (fields[2] != device) continue;
            return parse_disk_line(self.allocator, fields, self.ctx);
        }
    };
    return NOT_FOUND~;
}
