module linsys::network;
import linsys @public;
import std::io;
import std::collections::list;
import std::time;

const ushort AF_INET    = 2;
const ushort AF_INET6   = 10;
const uint IFF_UP       = 0x1;
const uint IFF_LOOPBACK = 0x8;

extern fn CInt getifaddrs(IfAddrs** ifap);
extern fn void freeifaddrs(IfAddrs* ifa);

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
    bool duplex_full;
    ulong flags;
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

fn NetIoCounters? parse_net_io_line(Allocator allocator, String line) @private {
    sz? idx = line.index_of_char(':');
    if (catch idx) return linsys::PARSE_ERROR~;

    String iface = line[:idx].trim();

    String[] fields = linsys::split_whitespace(tmem, line[idx + 1..].trim());

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

fn NetIoCounters[]? parse_net_io(
    Allocator allocator,
    File* file,
    List{NetIoCounters} list
) @private {
    int i = 0;
    while (try line = io::treadline(file)) {
        if (i++ < 2 || line.len == 0) continue;
        if (try counter = parse_net_io_line(allocator, line)) {
            list.push(counter);
        }
    }
    return list.to_array(allocator);
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

fn Connection[]? net_connections(Allocator allocator, Protocol[] protos = ALL_PROTOCOLS) {
    List{Connection} out;
    out.init(allocator);
    defer out.free();

    foreach (proto : protos) {
        File file = file::open(protocol_file(proto), "r")!;
        defer (void)file.close();
        read_system_connections(allocator, proto, &file, &out)!;
    }

    return out.to_array(allocator);
}

macro void? NetConnPoller.@poll(&self; @body(conns)) {
    @pool() {
        self.list.clear();
        for (usz i = 0; i < self.count; i++) {
            self.files[i].seek(0, FROM_START)!;
            read_system_connections(tmem, self.protos[i], &self.files[i], &self.list)!;
        }
        @body(self.list.array_view());
    };
}

fn NetConnPoller? net_conn_poller_new(Allocator allocator, Protocol[] protos = ALL_PROTOCOLS) {
    NetConnPoller p;
    p.allocator = allocator;
    p.list.init(allocator);
    p.count = protos.len;

    foreach (i, proto : protos) {
        p.protos[i] = proto;
        p.files[i] = file::open(protocol_file(proto), "r")!;
    }

    return p;
}

fn void NetConnPoller.close(&self) {
    for (usz i = 0; i < self.count; i++) {
        (void)self.files[i].close();
    }
    self.list.free();
}


fn NetIoCounters[]? net_io_counters(Allocator allocator) {
    List{NetIoCounters} list;
    defer list.free();

    @pool() {
        File file = file::open("/proc/net/dev", "r")!;
        defer (void)file.close();
        return parse_net_io(allocator, &file, list);
    };
}

fn void NetIoCounters[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void NetIoCounters.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

fn void? read_system_connections(
    Allocator allocator,
    Protocol proto,
    File* file,
    List{Connection}* out
) @private {
    @pool() {
        bool is_v6 = proto == Protocol.TCP6 || proto == Protocol.UDP6;
        int i      = 0;

        while (try line = io::treadline(file)) {
            if (i++ == 0 || line.len == 0) continue;
            String[] fields = linsys::split_whitespace(tmem, line.trim());
            if (fields.len < 4) continue;

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

            ushort lport;
            ushort rport;
            linsys::@try_field(lport, (ushort)local_port.to_long(16), "connection::local_port", 0);
            linsys::@try_field(rport, (ushort)remote_port.to_long(16), "connection::remote_port", 0);

            out.push(
                {
                    .local_addr = is_v6 ? linsys::ip_to_string_v6(
                        allocator,
                        linsys::parse_addr6(local_addr)
                    ) : linsys::ip_to_string(allocator, linsys::parse_addr(local_addr)),
                    .remote_addr = is_v6 ? linsys::ip_to_string_v6(
                        allocator,
                        linsys::parse_addr6(remote_addr)
                    ) : linsys::ip_to_string(allocator, linsys::parse_addr(remote_addr)),
                    .local_port = lport,
                    .remote_port = rport,
                    .state = linsys::tcp_state(fields[3]),
                    .protocol = proto,
                }
            );
        }
    };
}

fn String sockaddr_to_string(Allocator allocator, void* sa) @private {
    if (sa == null) return "";
    ushort family = *(ushort*)sa;
    switch (family) {
        case AF_INET:
            SockAddrIn* sin = (SockAddrIn*)sa;
            uint ip = sin.sin_addr;
            return string::format(
                allocator,
                "%d.%d.%d.%d",
                ip & 0xFF,
                (ip >> 8) & 0xFF,
                (ip >> 16) & 0xFF,
                (ip >> 24) & 0xFF
            );
        case AF_INET6:
            SockAddrIn6* sin6 = (SockAddrIn6*)sa;
            return string::format(
                allocator,
                "%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x",
                sin6.sin6_addr[0],
                sin6.sin6_addr[1],
                sin6.sin6_addr[2],
                sin6.sin6_addr[3],
                sin6.sin6_addr[4],
                sin6.sin6_addr[5],
                sin6.sin6_addr[6],
                sin6.sin6_addr[7],
                sin6.sin6_addr[8],
                sin6.sin6_addr[9],
                sin6.sin6_addr[10],
                sin6.sin6_addr[11],
                sin6.sin6_addr[12],
                sin6.sin6_addr[13],
                sin6.sin6_addr[14],
                sin6.sin6_addr[15]
            );
        default:
            return "";
    }
}

fn NetIfAddr[]? net_if_addrs(Allocator allocator) {
    IfAddrs* head = null;
    if (getifaddrs(&head) != 0) return linsys::IO_ERROR~;
    defer freeifaddrs(head);

    List{NetIfAddr} list;
    list.init(allocator);
    defer list.free();

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

    return list.to_array(allocator);
}

fn void NetIfAddr[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void NetIfAddr.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

fn NetIfStats[]? net_if_stats(Allocator allocator) {
    @pool() {
        Path path = path::new(tmem, "/sys/class/net")!;

        PathList list = io::path::ls(tmem, path)!;

        List{NetIfStats} stats;
        stats.init(allocator);
        defer stats.free();

        foreach (entry : list) {
            String? iface = entry.file_tbasename();
            if (catch iface) continue;

            NetIfStats st = { .name = iface.copy(allocator), };

            String base = string::tformat("/sys/class/net/%s", iface);

            String oper = string::tformat("%s/operstate", base);

            if (try File f = file::open(oper, "r")) {
                defer (void)f.close();
                String state = linsys::read_file(tmem, f)!.trim();
                st.is_up = state == "up";
            }

            String mtu = string::tformat("%s/mtu", base);

            if (try File f = file::open(mtu, "r")) {
                defer (void)f.close();
                st.mtu = linsys::read_file(tmem, f)!.trim().to_int() ?? 0;
            }

            String speed = string::tformat("%s/speed", base);

            if (try File f = file::open(speed, "r")) {
                defer (void)f.close();
                st.speed = linsys::read_file(tmem, f)!.trim().to_int() ?? 0;
            }

            String flags = string::tformat("%s/flags", base);

            if (try File f = file::open(flags, "r")) {
                defer (void)f.close();
                st.flags = linsys::read_file(tmem, f)!.trim().to_ulong(16) ?? 0;
            }

            stats.push(st);
        }

        return stats.to_array(allocator);
    };
}

fn void NetIfStats[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void NetIfStats.free(self, Allocator allocator) => linsys::free_fields(self, allocator);
