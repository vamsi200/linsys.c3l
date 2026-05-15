module c3sys;
import std::io;
import proc;
import std::thread;

fn int main(String[] args)
{
  while(true) { 
	//Connection[] cn = proc::proc_connections(tmem, 2802)!!;
	double p = proc::proc_create_time(2802)!!;
	io::printn(p);
	thread::sleep_ms(1000);
   }
	return 0;
}
