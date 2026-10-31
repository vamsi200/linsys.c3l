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
    double energy_now;
    double energy_full;
    double power_now;
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
        File? maybe_file = file::open(p.input, "r");
        if (catch maybe_file) {
            linsys::push_error("sensor_temperature::input", linsys::IO_ERROR);
            continue;
        }

        File f   = maybe_file;
        long raw = 0;

        if (try String line = io::treadline(&f)) {
            linsys::@try_field(raw, line.trim().to_long(), "sensor_temperature::value", 0);
        }

        (void)f.close();

        double critical = 0.0;

        if (try File cf = file::open(p.crit, "r")) {
            if (try String line = io::treadline(&cf)) {
                long crit = 0;

                linsys::@try_field(crit, line.trim().to_long(), "sensor_temperature::critical", 0);

                critical = (double)crit / 1000.0;
            }

            (void)cf.close();
        }

        out.push(
            {
                .name = p.name.copy(allocator),
                .current = (double)raw / 1000.0,
                .critical = critical,
            }
        );
    }
}

fn SensorPath[]? get_sensor_paths(Allocator allocator) @private => @pool() {
    Path path        = path::new(tmem, "/sys/class/hwmon")!;
    PathList entries = io::path::ls(tmem, path)!;

    List{SensorPath} paths;
    paths.init(allocator);

    bool transferred = false;

    defer {
        if (!transferred) {
            foreach (p : paths) {
                p.free(allocator);
            }
        }
        paths.free();
    }

    foreach (entry : entries) {
        String hwmon = entry.file_tbasename()!;
        String base  = string::tformat("/sys/class/hwmon/%s", hwmon);

        String name_path = string::tformat("%s/name", base);

        String sensor_name = hwmon;

        if (try File nf = file::open(name_path, "r")) {
            if (try String line = io::treadline(&nf)) {
                sensor_name = line.trim();
            }
            (void)nf.close();
        }

        for (int i = 1; i <= 32; i++) {
            String input = string::tformat("%s/temp%d_input", base, i);

            if (try File f = file::open(input, "r")) {
                (void)f.close();

                paths.push(
                    {
                        .input = input.copy(allocator),
                        .crit = string::format(allocator, "%s/temp%d_crit", base, i),
                        .name = string::format(allocator, "%s-temp%d", sensor_name, i),
                    }
                );
            }
        }
    }

    SensorPath[] result = paths.to_array(allocator);
    transferred = true;
    return result;
}

fn void SensorPath[].free(self, Allocator allocator) {
    foreach (p : self) {
        p.free(allocator);
    }
    mem::alloc::free(allocator, self);
}
fn void SensorPath.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

fn SensorTemperature[]? temperatures(Allocator allocator) => @pool() {
    SensorPath[] paths = get_sensor_paths(allocator)!;
    defer paths.free(allocator);

    List{SensorTemperature} out;
    out.init(allocator);

    bool transferred = false;

    defer {
        if (!transferred) {
            foreach (temp : out) {
                temp.free(allocator);
            }
        }
        out.free();
    }

    parse_sensor_temperatures(allocator, paths, &out)!;

    SensorTemperature[] result = out.to_array(allocator);
    transferred = true;
    return result;
}

fn void SensorTemperature[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void SensorTemperature.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

struct SensorPoller {
    SensorPath[] paths;
    List{SensorTemperature} list;
    Allocator allocator;
}

fn SensorPoller? sensor_poller(Allocator allocator) {
    SensorPath[] paths = get_sensor_paths(allocator)!;

    List{SensorTemperature} list;
    list.init(allocator);

    return {
        .paths = paths,
        .list = list,
        .allocator = allocator,
    };
}

macro void? SensorPoller.@poll(&self; @body(st)) {
    List{SensorTemperature} next;
    next.init(self.allocator);

    bool transferred = false;

    defer {
        if (!transferred) {
            foreach (temp : next) {
                temp.free(self.allocator);
            }
            next.free();
        }
    }

    parse_sensor_temperatures(self.allocator, self.paths, &next)!;

    List{SensorTemperature} previous = self.list;
    self.list = next;
    transferred = true;

    foreach (temp : previous) {
        temp.free(self.allocator);
    }
    previous.free();

    @body(self.list.array_view());
}

fn void SensorPoller.close(&self) {
    self.paths.free(self.allocator);

    foreach (temp : self.list) {
        temp.free(self.allocator);
    }

    self.list.free();
}


struct FanPath @private {
    String input;
    String name;
}

fn FanPath[]? find_fan_paths(Allocator allocator) @private => @pool() {
    Path path        = path::new(tmem, "/sys/class/hwmon")!;
    PathList entries = io::path::ls(tmem, path)!;

    List{FanPath} paths;
    paths.init(allocator);

    bool transferred = false;

    defer {
        if (!transferred) {
            foreach (p : paths) {
                p.free(allocator);
            }
        }
        paths.free();
    }

    foreach (entry : entries) {
        String hwmon = entry.file_tbasename()!;
        String base  = string::tformat("/sys/class/hwmon/%s", hwmon);

        String sensor_name = hwmon;
        String name_path   = string::tformat("%s/name", base);

        if (try File nf = file::open(name_path, "r")) {
            if (try String line = io::treadline(&nf)) {
                sensor_name = line.trim();
            }
            (void)nf.close();
        }

        for (int i = 1; i <= 32; i++) {
            String input = string::tformat("%s/fan%d_input", base, i);

            if (try File f = file::open(input, "r")) {
                (void)f.close();

                paths.push(
                    {
                        .input = input.copy(allocator),
                        .name = string::format(allocator, "%s-fan%d", sensor_name, i),
                    }
                );
            }
        }
    }

    FanPath[] result = paths.to_array(allocator);
    transferred = true;
    return result;
}

fn void? parse_sensor_fans(
    Allocator allocator,
    FanPath[] paths,
    List{SensorFan}* out,
    bool copy_names
) @private {
    foreach (p : paths) {
        ulong? raw = linsys::read_ulong_file(p.input);

        if (catch raw) {
            linsys::push_error("sensor_fans::input", linsys::IO_ERROR);
            continue;
        }

        if (raw > int::max) {
            linsys::push_error("sensor_fans::overflow", linsys::PARSE_ERROR);
            continue;
        }

        out.push(
            {
                .name = copy_names ? p.name.copy(allocator) : p.name,
                .current = (int)raw,
            }
        );
    }
}


fn void FanPath[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void FanPath.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

fn SensorFan[]? fans(Allocator allocator) => @pool() {
    FanPath[] paths = find_fan_paths(allocator)!;
    defer paths.free(allocator);

    List{SensorFan} out;
    out.init(allocator);

    bool transferred = false;

    defer {
        if (!transferred) {
            foreach (fan : out) {
                fan.free(allocator);
            }
        }
        out.free();
    }

    parse_sensor_fans(allocator, paths, &out, true)!;

    SensorFan[] result = out.to_array(allocator);
    transferred = true;
    return result;
}

fn void SensorFan[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void SensorFan.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

struct FanPoller {
    FanPath[] paths;
    List{SensorFan} list;
    Allocator allocator;
}

fn FanPoller? fan_poller(Allocator allocator) {
    FanPath[] paths = find_fan_paths(allocator)!;

    List{SensorFan} list;
    list.init(allocator, 8);

    return {
        .paths = paths,
        .list = list,
        .allocator = allocator,
    };
}


fn void FanPoller.close(&self) {
    self.list.free();
    self.paths.free(self.allocator);
}


macro void? FanPoller.@poll(&self; @body(fp)) {
    self.list.clear();
    parse_sensor_fans(self.allocator, self.paths, &self.list, false)!;
    return @body(self.list.array_view());
}

fn SensorBattery[]? batteries(Allocator allocator) => @pool() {
    Path path        = path::new(tmem, "/sys/class/power_supply")!;
    PathList entries = io::path::ls(tmem, path)!;

    List{SensorBattery} bats;
    bats.init(allocator);

    bool transferred = false;

    defer {
        if (!transferred) {
            foreach (bat : bats) {
                bat.free(allocator);
            }
        }
        bats.free();
    }

    foreach (entry : entries) {
        String name = entry.file_tbasename()!;
        String base = string::tformat("/sys/class/power_supply/%s", name);

        String type_path = string::tformat("%s/type", base);

        File? maybe_type = file::open(type_path, "r");
        if (catch maybe_type) continue;

        File tf     = maybe_type;
        String type = "";

        if (try String line = io::treadline(&tf)) {
            type = line.trim();
        }

        (void)tf.close();

        if (type != "Battery") continue;

        SensorBattery bat = {
            .name = name.copy(allocator),
        };

        String status_path = string::tformat("%s/status", base);

        if (try File sf = file::open(status_path, "r")) {
            if (try String line = io::treadline(&sf)) {
                bat.status = battery_status(line);
            }
            (void)sf.close();
        }

        ulong capacity = 0;

        linsys::@try_field(
            capacity,
            linsys::read_ulong_file(string::tformat("%s/capacity", base)),
            "sensor_battery::capacity",
            0
        );

        bat.percent = (double)capacity;

        ulong energy_now  = 0;
        ulong energy_full = 0;
        ulong power_now   = 0;

        linsys::@try_field(
            energy_now,
            linsys::read_ulong_file(string::tformat("%s/energy_now", base)),
            "sensor_battery::energy_now",
            0
        );

        linsys::@try_field(
            energy_full,
            linsys::read_ulong_file(string::tformat("%s/energy_full", base)),
            "sensor_battery::energy_full",
            0
        );

        linsys::@try_field(
            power_now,
            linsys::read_ulong_file(string::tformat("%s/power_now", base)),
            "sensor_battery::power_now",
            0
        );

        bat.energy_now = (double)energy_now / 1000000.0;
        bat.energy_full = (double)energy_full / 1000000.0;
        bat.power_now = (double)power_now / 1000000.0;

        if (bat.status == BatteryStatus.DISCHARGING) {
            if (bat.power_now > 0.0) {
                bat.secs_left = (long)(bat.energy_now / bat.power_now * 3600.0);
            } else {
                ulong charge_now  = 0;
                ulong current_now = 0;

                linsys::@try_field(
                    charge_now,
                    linsys::read_ulong_file(string::tformat("%s/charge_now", base)),
                    "sensor_battery::charge_now",
                    0
                );

                linsys::@try_field(
                    current_now,
                    linsys::read_ulong_file(string::tformat("%s/current_now", base)),
                    "sensor_battery::current_now",
                    0
                );

                if (current_now > 0) {
                    bat.secs_left = (long)((double)charge_now / (double)current_now * 3600.0);
                }
            }
        }

        bats.push(bat);
    }

    SensorBattery[] result = bats.to_array(allocator);
    transferred = true;
    return result;
}

fn void SensorBattery[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void SensorBattery.free(self, Allocator allocator) => linsys::free_fields(self, allocator);
