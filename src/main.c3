module c3sys;
import std::io;
import proc;

fn int main(String[] args)
{
  // ProcessInfo p = proc::proc_get_info(tmem, 1)!!;
  // io::printn(p);
  // int[] pid_list = proc::proc_list_pids(tmem)!!;
  // io::printn(pid_list);

  bool s = proc::proc_exists(1);
  io::printn(s);
	return 0;
}
