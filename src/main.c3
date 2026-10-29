import linsys @public;
import std::time;
import std::io;
import std::thread;
import std::os::posix;
import std::core::mem::allocators;

fn void bench_connections() @benchmark {
    @pool() {
        Connection[]? conns = network::connections(tmem);
        if (catch conns) return;
    };
}

fn void bench_cpu_times() @benchmark {
    @pool() {
        CpuTimes? t = process::cpu_times(posix::getpid());
        if (catch t) return;
    };
}

fn void bench_cpu_times_threads() @benchmark {
    @pool() {
        CpuTimes? t = process::cpu_times_threads(posix::getpid(), posix::getpid());
        if (catch t) return;
    };
}

fn void bench_process_poller_io_counters() @benchmark {
    @pool() {
        ProcessPoller? p = process::poller(posix::getpid());
        if (catch p) return;

        IoCounters? io = p.io_counters();
        if (catch io) return;
    };
}

fn void bench_cpu_snapshot() @benchmark {
    @pool() {
        CpuSnapshot? s = process::cpu_snapshot(posix::getpid());
        if (catch s) return;
    };
}

fn void bench_cpu_percent_from() @benchmark {
    @pool() {
        CpuSnapshot? s = process::cpu_snapshot(posix::getpid());
        if (catch s) return;

        double? p = process::cpu_percent_from(s, posix::getpid());
        if (catch p) return;
    };
}

fn void bench_cpu_percent() @benchmark {
    @pool() {
        double? p = process::cpu_percent(posix::getpid(), 0.0);
        if (catch p) return;
    };
}

fn void bench_children_non_recursive() @benchmark {
    @pool() {
        int[]? c = process::children(tmem, posix::getpid(), false);
        if (catch c) return;
    };
}

fn void bench_children_recursive() @benchmark {
    @pool() {
        int[]? c = process::children(tmem, posix::getpid(), true);
        if (catch c) return;
    };
}

struct ThreadCtx {
    int id;
}

fn void* poll_thread(void* arg) {
    ThreadCtx* ctx = (ThreadCtx*)arg;
    LibcAllocator libc;
    @pool_init(&libc, 8096) {
        TrackingAllocator tracker;
        tracker.init(tmem);
        defer tracker.free();
        defer if (tracker.has_leaks()) tracker.print_report();
        Allocator alloc = &tracker;

        disk::DiskContext dctx;
        dctx.init(alloc);
        defer dctx.free();

        // 	ulong sector_size = dctx.get_sector_size("nvme0n1");
        // io::printn(sector_size);

        DiskIoPoller dp = disk::poller(alloc, &dctx)!!;
        defer dp.close();

        dp.@poll_perdisk("sda1" ; c) {
            io::printn(dp.list);
        }!!;

        // Connection[] mp = process::connections(alloc, 3140)!!;
        // io::printn(mp);
        // defer mp.free(alloc);
    };
    return null;
}

fn void main(String[] args) {
    //    ThreadCtx ctx_a = { .id = 1 };
    //    ThreadCtx ctx_b = { .id = 2 };

    //    Thread ta, tb;
    //    ta.create((ThreadFn)&poll_thread, &ctx_a)!!;
    //    tb.create((ThreadFn)&poll_thread, &ctx_b)!!;
    //    ta.join()!!;
    //    tb.join()!!;

    @pool() {
        while (true) {
            RLimitEntry[] rl = process::rlimits_get(tmem, 2231)!!;
            foreach (r: rl) io::printn(r);
            thread::sleep_ms(250);
        }
    };
}
