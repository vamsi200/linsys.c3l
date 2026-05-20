module main;
module sys;
import std::io;
import std::thread;

fn int main(String[] args) {
	SensorBattery[] na = sensor_battery(tmem) ?? {};
	foreach (n: na) io::printn(n);
	
    return 0;
}
