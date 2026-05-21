module sys;
import std::io;
import libc;
import std::collections::list;
import std::collections::map;

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

            String[] fields = line.split(tmem, " ");
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

HashMap{String, ulong} sector_size_cache;
bool init_sec_size = false;

// Not thread safe?
fn ulong get_sector_size(Allocator allocator, String device) {
    if (!init_sec_size) {
        sector_size_cache.init(allocator);
        init_sec_size = true;
    }

    if (try ulong size = sector_size_cache.get(device)) return size;

    @pool() {
        String sector_path = string::tformat("/sys/block/%s/queue/physical_block_size", device);
        ulong size         = read_ulong_file(sector_path) ?? 512;
        sector_size_cache.set(device.copy(allocator), size);
        return size;
    };
}

const int DISKSTATS_MIN_FIELDS = 14; // kernel 2.6+

fn DiskIoCounters[]? disk_io_counters(Allocator allocator) {
    @pool() {
        File file = file::open("/proc/diskstats", "r")!;
        defer (void)file.close();
        String content = read_file(tmem, file)!;
        List{DiskIoCounters} disks;
        disks.init(allocator);

        foreach (line : content.split(tmem, "\n")) {
            if (line.len == 0) continue;
            String[] fields = line.trim().split(tmem, " ");
            if (fields.len < DISKSTATS_MIN_FIELDS) continue;
            ulong sector_size = get_sector_size(allocator, fields[2]);

            disks.push(
                {
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
                }
            );
        }
        return disks.to_array(allocator);
    };
}
