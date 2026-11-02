module linsys::network;
import linsys @public;
import std::io;
import std::collections::list;
import std::time;

const ushort AF_INET    = 2;
const ushort AF_INET6   = 10;
const uint IFF_UP       = 0x1;
const uint IFF_LOOPBACK = 0x8;

extern fn CInt getifaddrs(IfAddrs** ifap) @private;
extern fn void freeifaddrs(IfAddrs* ifa) @private;

struct NetIoCounters {
    String name;
    ulong bytes_sent;
    ulong bytes_recv;
    ulong packets_sent;
    ulong packets_recv;
    ulong errin;
    ulong errout;
    ulong dropin;
    ulong dropout;
}

struct NetIfStats {
    String name;
    bool is_up;
    int mtu;
    int speed;
    NetDuplex duplex;
    ulong flags;
    String operstate;
    String mac_address;
}

struct IfAddrs {
    IfAddrs* next;
    ZString ifa_name;
    uint ifa_flags;
    void* ifa_addr;
    void* ifa_netmask;
    void* ifa_ifu;
    void* ifa_data;
}

struct SockAddrIn {
    ushort sin_family;
    ushort sin_port;
    uint sin_addr;
    char[8] sin_zero;
}

struct SockAddrIn6 {
    ushort sin6_family;
    ushort sin6_port;
    uint sin6_flowinfo;
    char[16] sin6_addr;
    uint sin6_scope_id;
}

struct NetIfAddr {
    String name;
    String address;
    String netmask;
    bool is_up;
    bool is_loopback;
}

struct NetIoPoller {
    File file;
    List{NetIoCounters} list;
    Allocator allocator;
}

struct NetConnPoller {
    File[4] files;
    Protocol[4] protos;
    usz count;
    List{Connection} list;
    Allocator allocator;
}

fn NetIoCounters? parse_net_io_line(Allocator allocator, String line) @private => @pool() {
    sz? idx = line.index_of_char(':');
    if (catch idx) return linsys::PARSE_ERROR~;

    String iface = line[:idx].trim();

    String[] fields = linsys::split_whitespace(line[idx + 1..].trim());

    ulong bytes_recv, packets_recv, errin, dropin;
    ulong bytes_sent, packets_sent, errout, dropout;

    if (fields.len > 0) linsys::@try_field(
        bytes_recv,
        fields[0].to_ulong(),
        "netiface::bytes_recv",
        0
    );
    if (fields.len > 1) linsys::@try_field(
        packets_recv,
        fields[1].to_ulong(),
        "netiface::packets_recv",
        0
    );
    if (fields.len > 2) linsys::@try_field(errin, fields[2].to_ulong(), "netiface::errin", 0);
    if (fields.len > 3) linsys::@try_field(dropin, fields[3].to_ulong(), "netiface::dropin", 0);
    if (fields.len > 8) linsys::@try_field(
        bytes_sent,
        fields[8].to_ulong(),
        "netiface::bytes_sent",
        0
    );
    if (fields.len > 9) linsys::@try_field(
        packets_sent,
        fields[9].to_ulong(),
        "netiface::packets_sent",
        0
    );
    if (fields.len > 10) linsys::@try_field(errout, fields[10].to_ulong(), "netiface::errout", 0);
    if (fields.len > 11) linsys::@try_field(dropout, fields[11].to_ulong(), "netiface::dropout", 0);

    return {
        .name = iface.copy(allocator),
        .bytes_recv = bytes_recv,
        .packets_recv = packets_recv,
        .errin = errin,
        .dropin = dropin,
        .bytes_sent = bytes_sent,
        .packets_sent = packets_sent,
        .errout = errout,
        .dropout = dropout,
    };
}

fn void? parse_net_io(Allocator allocator, File* file, List{NetIoCounters}* list) @private {
    int i = 0;

    while (try line = io::treadline(file)) {
        if (i++ < 2 || line.len == 0) continue;

        if (try counter = parse_net_io_line(allocator, line)) {
            list.push(counter);
        } else {
            linsys::push_error("netio::line", linsys::PARSE_ERROR);
        }
    }
}

const Protocol[] ALL_PROTOCOLS = { TCP, UDP, TCP6, UDP6 };

fn String protocol_file(Protocol proto) @private {
    switch (proto) {
        case TCP: return "/proc/net/tcp";
        case UDP: return "/proc/net/udp";
        case TCP6: return "/proc/net/tcp6";
        case UDP6: return "/proc/net/udp6";
    }
}

fn Connection[]? connections(Allocator allocator, Protocol[] protos = ALL_PROTOCOLS) {
    List{Connection} out;
    out.init(allocator);

    bool transferred = false;

    defer {
        if (!transferred) {
            foreach (conn : out) {
                conn.free(allocator);
            }
        }
        out.free();
    }

    foreach (proto : protos) {
        File file = file::open(protocol_file(proto), "r")!;
        defer (void)file.close();
        read_system_connections(allocator, proto, &file, &out)!;
    }

    Connection[] result = out.to_array(allocator);
    transferred = true;
    return result;
}

fn NetIoPoller? io_poller(Allocator allocator) {
    File file = file::open("/proc/net/dev", "r")!;

    List{NetIoCounters} list;
    list.init(allocator);

    return {
        .file = file,
        .list = list,
        .allocator = allocator,
    };
}

macro void? NetIoPoller.@poll(&self; @body(stats)) => @pool() {
    List{NetIoCounters} next;
    next.init(self.allocator);

    bool transferred = false;

    defer {
        if (!transferred) {
            foreach (counter : next) {
                counter.free(self.allocator);
            }
            next.free();
        }
    }

    self.file.seek(0, FROM_START)!;

    parse_net_io(self.allocator, &self.file, &next)!;

    List{NetIoCounters} previous = self.list;
    self.list = next;
    transferred = true;

    foreach (counter : previous) {
        counter.free(self.allocator);
    }
    previous.free();

    @body(self.list.array_view());
}

fn void NetIoPoller.close(&self) {
    (void)self.file.close();

    foreach (counter : self.list) {
        counter.free(self.allocator);
    }

    self.list.free();
}

fn NetConnPoller? poller(Allocator allocator, Protocol[] protos = ALL_PROTOCOLS) {
    if (protos.len > 4) return linsys::INVALID_LENGTH~;

    NetConnPoller p = { };
    p.allocator = allocator;
    p.list.init(allocator);

    foreach (proto : protos) {
        File? maybe_file = file::open(protocol_file(proto), "r");

        if (catch err = maybe_file) {
            for (usz i = 0; i < p.count; i++) {
                (void)p.files[i].close();
            }

            p.list.free();
            return err~;
        }

        p.protos[p.count] = proto;
        p.files[p.count] = maybe_file;
        p.count++;
    }

    return p;
}


macro void? NetConnPoller.@poll(&self; @body(conns)) => @pool() {
    List{Connection} next;
    next.init(self.allocator);

    bool transferred = false;

    defer {
        if (!transferred) {
            foreach (conn : next) {
                conn.free(self.allocator);
            }
            next.free();
        }
    }

    for (usz i = 0; i < self.count; i++) {
        self.files[i].seek(0, FROM_START)!;

        read_system_connections(self.allocator, self.protos[i], &self.files[i], &next)!;
    }

    List{Connection} previous = self.list;
    self.list = next;
    transferred = true;

    foreach (conn : previous) {
        conn.free(self.allocator);
    }
    previous.free();

    @body(self.list.array_view());
}

fn void NetConnPoller.close(&self) {
    for (usz i = 0; i < self.count; i++) {
        (void)self.files[i].close();
    }

    foreach (conn : self.list) {
        conn.free(self.allocator);
    }

    self.list.free();
}

fn NetIoCounters[]? io_counters(Allocator allocator) => @pool() {
    File file = file::open("/proc/net/dev", "r")!;
    defer (void)file.close();

    List{NetIoCounters} list;
    list.init(allocator);

    bool transferred = false;

    defer {
        if (!transferred) {
            foreach (counter : list) {
                counter.free(allocator);
            }
        }
        list.free();
    }

    parse_net_io(allocator, &file, &list)!;

    NetIoCounters[] result = list.to_array(allocator);
    transferred = true;

    return result;
}

fn void NetIoCounters[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void NetIoCounters.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

fn void? read_system_connections(
    Allocator allocator,
    Protocol proto,
    File* file,
    List{Connection}* out
) @private => @pool() {
    bool is_v6 = proto == Protocol.TCP6 || proto == Protocol.UDP6;
    int i      = 0;

    while (try line = io::treadline(file)) {
        if (i++ == 0 || line.len == 0) continue;
        String[] fields = linsys::split_whitespace(line.trim());
        if (fields.len < 4) {
            linsys::push_error("connection::line", linsys::PARSE_ERROR);
            continue;
        }

        sz? colon_l = fields[1].index_of_char(':');
        sz? colon_r = fields[2].index_of_char(':');

        if (catch colon_l) {
            linsys::push_error("connection::local_addr", linsys::PARSE_ERROR);
            continue;
        }
        if (catch colon_r) {
            linsys::push_error("connection::remote_addr", linsys::PARSE_ERROR);
            continue;
        }

        String local_addr  = fields[1][:colon_l];
        String local_port  = fields[1][colon_l + 1..];
        String remote_addr = fields[2][:colon_r];
        String remote_port = fields[2][colon_r + 1..];

        long? parsed_local  = local_port.to_long(16);
        long? parsed_remote = remote_port.to_long(16);

        if (catch parsed_local) {
            linsys::push_error("connection::local_port", linsys::PARSE_ERROR);
            continue;
        }

        if (catch parsed_remote) {
            linsys::push_error("connection::remote_port", linsys::PARSE_ERROR);
            continue;
        }

        if (parsed_local < 0 || parsed_local > 65535 || parsed_remote < 0
            || parsed_remote > 65535) {
            linsys::push_error("connection::port", linsys::PARSE_ERROR);
            continue;
        }

        ushort lport = (ushort)parsed_local;
        ushort rport = (ushort)parsed_remote;

        out.push(
            {
                .local_addr = is_v6 ? linsys::ip_to_string_v6(
                    allocator,
                    linsys::parse_addr6(local_addr)
                )
                    : linsys::ip_to_string(allocator, linsys::parse_addr(local_addr)),
                .remote_addr = is_v6 ? linsys::ip_to_string_v6(
                    allocator,
                    linsys::parse_addr6(remote_addr)
                )
                    : linsys::ip_to_string(allocator, linsys::parse_addr(remote_addr)),
                .local_port = lport,
                .remote_port = rport,
                .state = linsys::tcp_state(fields[3]),
                .protocol = proto,
            }
        );
    }
}

extern fn ZString inet_ntop(CInt af, void* src, char* dst, uint size) @private;

fn String sockaddr_to_string(Allocator allocator, void* sa) @private {
    if (sa == null) return "".copy(allocator);

    ushort family = *(ushort*)sa;

    char[46] buffer = { };

    void* addr = null;

    switch (family) {
        case AF_INET:
            SockAddrIn* sin = (SockAddrIn*)sa;
            addr = &sin.sin_addr;

        case AF_INET6:
            SockAddrIn6* sin6 = (SockAddrIn6*)sa;
            addr = &sin6.sin6_addr;

        default:
            return "".copy(allocator);
    }

    if (inet_ntop((CInt)family, addr, &buffer[0], 46) == null) {
        linsys::push_error("netifaddr::inet_ntop", linsys::IO_ERROR);
        return "".copy(allocator);
    }

    return ((ZString)&buffer[0]).str_view().copy(allocator);
}

fn NetIfAddr[]? interface_addrs(Allocator allocator) {
    IfAddrs* head = null;
    if (getifaddrs(&head) != 0) return linsys::IO_ERROR~;
    defer freeifaddrs(head);

    List{NetIfAddr} list;
    list.init(allocator);

    bool transferred = false;

    defer {
        if (!transferred) {
            foreach (addr : list) {
                addr.free(allocator);
            }
        }
        list.free();
    }

    IfAddrs* cur = head;
    while (cur != null) {
        if (cur.ifa_addr != null) {
            ushort family = *(ushort*)cur.ifa_addr;
            if (family == AF_INET || family == AF_INET6) {
                list.push(
                    {
                        .name = ((String)cur.ifa_name.str_view()).copy(allocator),
                        .address = sockaddr_to_string(allocator, cur.ifa_addr),
                        .netmask = sockaddr_to_string(allocator, cur.ifa_netmask),
                        .is_up = (cur.ifa_flags & IFF_UP) != 0,
                        .is_loopback = (cur.ifa_flags & IFF_LOOPBACK) != 0,
                    }
                );
            }
        }
        cur = cur.next;
    }

    NetIfAddr[] result = list.to_array(allocator);
    transferred = true;
    return result;
}

fn void NetIfAddr[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void NetIfAddr.free(self, Allocator allocator) => linsys::free_fields(self, allocator);


constdef NetDuplex : int {
    UNKNOWN = 0,
    HALF    = 1,
    FULL    = 2,
}


fn NetIfStats[]? interface_stats(Allocator allocator) => @pool() {
    Path path        = path::new(tmem, "/sys/class/net")!;
    PathList entries = io::path::ls(tmem, path)!;

    List{NetIfStats} stats;
    stats.init(allocator);

    bool transferred = false;

    defer {
        if (!transferred) {
            foreach (st : stats) {
                st.free(allocator);
            }
        }
        stats.free();
    }

    foreach (entry : entries) {
        String? maybe_iface = entry.file_tbasename();
        if (catch maybe_iface) continue;

        String iface = maybe_iface;

        NetIfStats st = {
            .name = iface.copy(allocator),
            .duplex = NetDuplex.UNKNOWN,
            .operstate = "unknown".copy(allocator),
            .mac_address = "".copy(allocator),
        };

        String base       = string::tformat("/sys/class/net/%s", iface);
        String flags_path = string::tformat("%s/flags", base);

        if (try File f = file::open(flags_path, "r")) {
            defer (void)f.close();

            if (try String raw = linsys::read_file(f)) {
                String value = raw.trim();
                String hex   = value.starts_with("0x") ? value[2..] : value;

                linsys::@try_field(st.flags, hex.to_ulong(16), "netifstats::flags", 0);
            } else {
                linsys::push_error("netifstats::flags", linsys::IO_ERROR);
            }
        }

        st.is_up = (st.flags & IFF_UP) != 0;

        String mtu_path = string::tformat("%s/mtu", base);

        if (try File f = file::open(mtu_path, "r")) {
            defer (void)f.close();

            if (try String raw = linsys::read_file(f)) {
                linsys::@try_field(st.mtu, raw.trim().to_int(), "netifstats::mtu", 0);
            } else {
                linsys::push_error("netifstats::mtu", linsys::IO_ERROR);
            }
        }

        String speed_path = string::tformat("%s/speed", base);
        if (try File f = file::open(speed_path, "r")) {
            defer (void)f.close();
            if (try String raw = linsys::read_file(f)) {
                long? parsed_speed = raw.trim().to_long();
                if (catch parsed_speed) continue;
                st.speed = (int)parsed_speed;
                if (st.speed < 0) st.speed = 0;
            }
        }

        String duplex_path = string::tformat("%s/duplex", base);
        if (try File f = file::open(duplex_path, "r")) {
            defer (void)f.close();
            if (try String raw = linsys::read_file(f)) {
                switch (raw.trim()) {
                    case "full": st.duplex = NetDuplex.FULL;
                    case "half": st.duplex = NetDuplex.HALF;
                    default: st.duplex = NetDuplex.UNKNOWN;
                }
            }
        }

        String oper_path = string::tformat("%s/operstate", base);
        if (try File f = file::open(oper_path, "r")) {
            defer (void)f.close();
            if (try String raw = linsys::read_file(f)) {
                mem::alloc::free(allocator, st.operstate);
                st.operstate = raw.trim().copy(allocator);
            }
        }

        String mac_path = string::tformat("%s/address", base);
        if (try File f = file::open(mac_path, "r")) {
            defer (void)f.close();
            if (try String raw = linsys::read_file(f)) {
                mem::alloc::free(allocator, st.mac_address);
                st.mac_address = raw.trim().copy(allocator);
            }
        }

        stats.push(st);
    }

    NetIfStats[] result = stats.to_array(allocator);
    transferred = true;

    return result;
}

fn void NetIfStats[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void NetIfStats.free(self, Allocator allocator) => linsys::free_fields(self, allocator);


struct NetIoRates {
    double bytes_sent_per_sec;
    double bytes_recv_per_sec;
    double packets_sent_per_sec;
    double packets_recv_per_sec;
    double errors_per_sec;
    double drops_per_sec;
}

fn NetIoRates io_rates(NetIoCounters previous, NetIoCounters current, double elapsed_seconds) {
    NetIoRates rates = { };

    if (elapsed_seconds <= 0.0) return rates;

    ulong sent         = 0;
    ulong recv         = 0;
    ulong packets_sent = 0;
    ulong packets_recv = 0;

    linsys::@try_field(
        sent,
        system::counter_delta(previous.bytes_sent, current.bytes_sent),
        "netrates::bytes_sent",
        0
    );

    linsys::@try_field(
        recv,
        system::counter_delta(previous.bytes_recv, current.bytes_recv),
        "netrates::bytes_recv",
        0
    );

    linsys::@try_field(
        packets_sent,
        system::counter_delta(previous.packets_sent, current.packets_sent),
        "netrates::packets_sent",
        0
    );

    linsys::@try_field(
        packets_recv,
        system::counter_delta(previous.packets_recv, current.packets_recv),
        "netrates::packets_recv",
        0
    );

    rates.bytes_sent_per_sec = (double)sent / elapsed_seconds;
    rates.bytes_recv_per_sec = (double)recv / elapsed_seconds;
    rates.packets_sent_per_sec = (double)packets_sent / elapsed_seconds;
    rates.packets_recv_per_sec = (double)packets_recv / elapsed_seconds;

    return rates;
}


<*
 @require iface.len > 0 : "interface name must not be empty"
*>
fn NetIoCounters? io_counters_pernic(Allocator allocator, String iface) => @pool() {
    File file = file::open("/proc/net/dev", "r")!;
    defer (void)file.close();

    int i = 0;

    while (try line = io::treadline(&file)) {
        if (i++ < 2 || line.len == 0) continue;

        sz? colon = line.index_of_char(':');
        if (catch colon) continue;

        if (line[:colon].trim() != iface) continue;

        return parse_net_io_line(allocator, line);
    }

    return linsys::NOT_FOUND~;
}

struct SockStat {
    ulong sockets_used;
    ulong tcp_inuse;
    ulong tcp_orphan;
    ulong tcp_tw;
    ulong tcp_alloc;
    ulong udp_inuse;
    ulong memory_pages;
}

fn SockStat? sockstat() => @pool() {
    File file = file::open("/proc/net/sockstat", "r")!;
    defer (void)file.close();

    SockStat stats = { };

    while (try line = io::treadline(&file)) {
        if (line.len == 0) continue;

        sz? colon = line.index_of_char(':');
        if (catch colon) continue;

        String key      = line[:colon].trim();
        String[] fields = linsys::split_whitespace(line[colon + 1..].trim());

        if (key == "sockets") {
            for (usz i = 0; i < fields.len; i += 2) {
                if (fields[i] == "used") {
                    linsys::@try_field(
                        stats.sockets_used,
                        fields[i + 1].to_ulong(),
                        "sockstat::sockets_used",
                        0
                    );
                }
            }
        } else if (key == "TCP") {
            for (usz i = 0; i < fields.len; i += 2) {
                String subkey = fields[i];
                if (i + 1 >= fields.len) break;

                if (subkey == "inuse") {
                    linsys::@try_field(
                        stats.tcp_inuse,
                        fields[i + 1].to_ulong(),
                        "sockstat::tcp_inuse",
                        0
                    );
                } else if (subkey == "orphan") {
                    linsys::@try_field(
                        stats.tcp_orphan,
                        fields[i + 1].to_ulong(),
                        "sockstat::tcp_orphan",
                        0
                    );
                } else if (subkey == "tw") {
                    linsys::@try_field(
                        stats.tcp_tw,
                        fields[i + 1].to_ulong(),
                        "sockstat::tcp_tw",
                        0
                    );
                } else if (subkey == "alloc") {
                    linsys::@try_field(
                        stats.tcp_alloc,
                        fields[i + 1].to_ulong(),
                        "sockstat::tcp_alloc",
                        0
                    );
                } else if (subkey == "mem") {
                    linsys::@try_field(
                        stats.memory_pages,
                        fields[i + 1].to_ulong(),
                        "sockstat::memory_pages",
                        0
                    );
                }
            }
        } else if (key == "UDP") {
            for (usz i = 0; i < fields.len; i += 2) {
                if (fields[i] == "inuse") {
                    linsys::@try_field(
                        stats.udp_inuse,
                        fields[i + 1].to_ulong(),
                        "sockstat::udp_inuse",
                        0
                    );
                }
            }
        }
    }

    return stats;
}

// tests
fn void test_net_io_counters() @test {
    linsys::@tracker(; Allocator alloc) {
        NetIoCounters[]? counters_opt = io_counters(alloc);
        if (catch err = counters_opt) return;

        NetIoCounters[] counters = counters_opt;
        defer counters.free(alloc);

        assert(counters.len > 0);
        foreach (c : counters) {
            assert(c.name.len > 0);
        }
    };
}

fn void test_net_interface_stats() @test {
    linsys::@tracker(; Allocator alloc) {
        NetIfStats[]? stats_opt = interface_stats(alloc);
        if (catch err = stats_opt) return;

        NetIfStats[] stats = stats_opt;
        defer stats.free(alloc);

        assert(stats.len > 0);
        bool found_loopback = false;
        foreach (st : stats) {
            if (st.name == "lo") {
                found_loopback = true;
                assert(st.mtu > 0);
            }
        }
        assert(found_loopback);
    };
}

fn void test_net_interface_stats_hardware_fields() @test {
    linsys::@tracker(; Allocator alloc) {
        NetIfStats[]? stats_opt = interface_stats(alloc);
        if (catch err = stats_opt) return;

        NetIfStats[] stats = stats_opt;
        defer stats.free(alloc);

        assert(stats.len > 0);
        foreach (st : stats) {
            assert(st.operstate.len > 0);

            if (st.name != "lo") {
                assert(st.mac_address.len >= 0);
            }
        }
    };
}

fn void test_net_conn_poller() @test {
    linsys::@tracker(; Allocator alloc) {
        NetConnPoller poller = network::poller(alloc)!!;
        poller.close();
    };
}

fn void test_net_if_addr() @test {
    linsys::@tracker(; Allocator alloc) {
        NetIfAddr[]? addrs = network::interface_addrs(alloc);
        if (catch addrs) return;
        addrs.free(alloc);
    };
}
