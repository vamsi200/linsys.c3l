module linsys::sensors;
import linsys @public;
import std::io;
import std::collections::list;

struct SensorTemperature {
    String name;
    double current;
    double critical;
}

struct SensorFan {
    String name;
    int current;
}

struct SensorBattery {
    String name;
    double percent;
    BatteryStatus status;
    ulong energy_now;
    ulong energy_full;
    ulong power_now;
    long secs_left;
}

enum BatteryStatus {
    UNKNOWN,
    CHARGING,
    DISCHARGING,
    FULL,
    NOT_CHARGING,
}

struct SensorPath @private {
    String input;
    String crit;
    String name;
}

fn BatteryStatus battery_status(String s) @private {
    switch (s.trim()) {
        case "Charging":
            return BatteryStatus.CHARGING;

        case "Discharging":
            return BatteryStatus.DISCHARGING;

        case "Full":
            return BatteryStatus.FULL;

        case "Not charging":
            return BatteryStatus.NOT_CHARGING;

        default:
            return BatteryStatus.UNKNOWN;
    }
}


fn void? parse_sensor_temperatures(
    Allocator allocator,
    SensorPath[] paths,
    List{SensorTemperature}* out
) @private {
    foreach (p : paths) {
        ulong? raw = linsys::read_ulong_file(p.input);
        if (catch raw) continue;

        double current  = (double)raw / 1000.0;
        double critical = 0.0;
        ulong? crit_raw = linsys::read_ulong_file(p.crit);

        if (try crit_raw) {
            critical = (double)crit_raw / 1000.0;
        }

        out.push({ .name = p.name, .current = current, .critical = critical, });
    }
}

fn SensorPath[]? get_sensor_paths(Allocator allocator) @private => @pool() {
    Path path     = path::new(tmem, "/sys/class/hwmon")!;
    PathList list = io::path::ls(tmem, path)!;
    List{SensorPath} paths;
    paths.init(allocator);
    defer paths.free();

    foreach (entry : list) {
        String hwmon     = entry.file_tbasename()!;
        String base      = string::tformat("/sys/class/hwmon/%s", hwmon);
        String name_path = string::tformat("%s/name", base);
        String sensor_name;

        if (try File nf = file::open(name_path, "r")) {
            defer (void)nf.close();
            sensor_name = io::treadline(&nf)!.trim().copy(allocator);
        } else {
            sensor_name = hwmon.copy(allocator);
        }

        defer mem::alloc::free(allocator, sensor_name);

        for (int i = 1; i <= 32; i++) {
            String input = string::tformat("%s/temp%d_input", base, i);
            ulong? raw   = linsys::read_ulong_file(input);
            if (catch raw) {
                linsys::push_error("sensorpath::line", linsys::PARSE_ERROR);
                continue;
            }

            paths.push(
                { .input = input.copy(allocator), .crit = string::tformat("%s/temp%d_crit", base, i)
                .copy(
                    allocator
                ), .name = string::format(allocator, "%s-temp%d", sensor_name, i), });
        }
    }
    return paths.to_array(allocator);
}

fn void SensorPath[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void SensorPath.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

fn SensorTemperature[]? temperatures(Allocator allocator) => @pool() {
    SensorPath[] paths = get_sensor_paths(allocator)!;
    linsys::free_slice(paths, allocator);

    List{SensorTemperature} out;
    out.init(allocator);
    defer out.free();

    parse_sensor_temperatures(allocator, paths, &out)!;
    return out.to_array(allocator);
}

fn void SensorTemperature[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void SensorTemperature.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

struct SensorPoller {
    SensorPath[] paths;
    List{SensorTemperature} list;
    Allocator allocator;
}

fn SensorPoller? sensor_poller(Allocator allocator) {
    List{SensorTemperature} list;
    list.init(allocator);
    return { .paths = get_sensor_paths(allocator)!, .list = list, .allocator = allocator, };
}

fn void SensorPoller.close(&self) {
    linsys::free_slice(self.paths, self.allocator);
    self.list.free();
}

macro void? SensorPoller.@poll(&self; @body(st)) {
    self.list.clear();
    parse_sensor_temperatures(self.allocator, self.paths, &self.list)!;
    @body(self.list.array_view());
}

struct FanPath @private {
    String input;
    String name;
}

fn FanPath[]? find_fan_paths(Allocator allocator) @private => @pool() {
    Path path     = path::new(tmem, "/sys/class/hwmon")!;
    PathList list = io::path::ls(tmem, path)!;
    List{FanPath} paths;
    paths.init(allocator);
    defer paths.free();

    foreach (entry : list) {
        String hwmon     = entry.file_tbasename()!;
        String base      = string::tformat("/sys/class/hwmon/%s", hwmon);
        String name_path = string::tformat("%s/name", base);
        String sensor_name;
        if (try File nf = file::open(name_path, "r")) {
            defer (void)nf.close();
            sensor_name = io::treadline(&nf)!.trim().copy(allocator);
        } else {
            sensor_name = hwmon.copy(allocator);
        }

        defer mem::alloc::free(allocator, sensor_name);

        for (int i = 1; i <= 32; i++) {
            String input = string::tformat("%s/fan%d_input", base, i);
            ulong? raw   = linsys::read_ulong_file(input);
            if (catch raw) {
                linsys::push_error("fanpath::line", linsys::PARSE_ERROR);
                continue;
            }

            paths.push(
                {
                    .input = input.copy(allocator),
                    .name = string::format(allocator, "%s-fan%d", sensor_name, i),
                }
            );
        }
    }
    return paths.to_array(allocator);
}

fn void? parse_sensor_fans(Allocator allocator, FanPath[] paths, List{SensorFan}* out) @private {
    foreach (p : paths) {
        ulong? raw = linsys::read_ulong_file(p.input);
        if (catch raw) {
            linsys::push_error("sensor_fans::line", linsys::PARSE_ERROR);
            continue;
        }
        out.push({ .name = p.name.copy(allocator), .current = (int)raw, });
    }
}

fn void FanPath.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

fn SensorFan[]? fans(Allocator allocator) => @pool() {
    FanPath[] paths = find_fan_paths(allocator)!;
    linsys::free_slice(paths, allocator);

    List{SensorFan} out;
    out.init(allocator);
    defer out.free();
    parse_sensor_fans(allocator, paths, &out)!;
    return out.to_array(allocator);
}

fn void SensorFan[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void SensorFan.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

struct FanPoller {
    FanPath[] paths;
    List{SensorFan} list;
    Allocator allocator;
}

fn FanPoller? fan_poller(Allocator allocator) {
    List{SensorFan} list;
    list.init(allocator, 8);
    return { .paths = find_fan_paths(allocator)!, .list = list, .allocator = allocator, };
}

fn void FanPoller.close(&self) {
    foreach (p : self.paths) {
        mem::alloc::free(self.allocator, p.input);
        mem::alloc::free(self.allocator, p.name);
    }
    mem::alloc::free(self.allocator, self.paths.ptr);
    self.list.free();
}

macro void? FanPoller.@poll(&self; @body(fp)) {
    self.list.clear();
    parse_sensor_fans(self.allocator, self.paths, &self.list)!;
    return @body(self.list.to_array(self.allocator));
}

fn SensorBattery[]? batteries(Allocator allocator) {
    @pool() {
        Path path     = path::new(tmem, "/sys/class/power_supply")!;
        PathList list = io::path::ls(tmem, path)!;
        List{SensorBattery} bats;
        bats.init(allocator);
        defer bats.free();

        foreach (entry : list) {
            String name      = entry.file_tbasename()!;
            String base      = string::tformat("/sys/class/power_supply/%s", name);
            String type_path = string::tformat("%s/type", base);
            File? tf         = file::open(type_path, "r");
            if (catch tf) continue;
            defer (void)tf.close();

            String type = io::treadline(&tf)!.trim();
            if (type != "Battery") continue;
            SensorBattery bat = { .name = name.copy(allocator) };
            String status     = string::tformat("%s/status", base);

            if (try File sf = file::open(status, "r")) {
                defer (void)sf.close();
                bat.status = battery_status(io::treadline(&sf)!.trim());
            }

            ulong capacity;
            linsys::@try_field(
                capacity,
                linsys::read_ulong_file(string::tformat("%s/capacity", base)),
                "sensor_battery::percent",
                0
            );
            linsys::@try_field(
                bat.energy_now,
                linsys::read_ulong_file(string::tformat("%s/energy_now", base)),
                "sensor_battery::energy_now",
                0
            );
            linsys::@try_field(
                bat.energy_full,
                linsys::read_ulong_file(string::tformat("%s/energy_full", base)),
                "sensor_battery::energy_full",
                0
            );
            linsys::@try_field(
                bat.power_now,
                linsys::read_ulong_file(string::tformat("%s/power_now", base)),
                "sensor_battery::power_now",
                0
            );
            bat.percent = (double)capacity;


            if (bat.power_now > 0 && bat.energy_now > 0) {
                bat.secs_left = ((long)((double)bat.energy_now / (double)bat.power_now)) * 3600;
            }
            bats.push(bat);
        }
        return bats.to_array(allocator);
    };
}

fn void SensorBattery[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void SensorBattery.free(self, Allocator allocator) => linsys::free_fields(self, allocator);