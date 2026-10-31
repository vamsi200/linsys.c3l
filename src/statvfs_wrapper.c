#include <stdint.h>
#include <sys/statvfs.h>

struct Statvfs {
  uint64_t block_size;
  uint64_t fragment_size;
  uint64_t blocks;
  uint64_t blocks_free;
  uint64_t blocks_available;
  uint64_t files;
  uint64_t files_free;
  uint64_t files_available;
  uint64_t name_max;
};

int _statvfs(const char *path, struct Statvfs *out) {
  struct statvfs s;

  if (statvfs(path, &s) != 0)
    return -1;

  *out = (struct Statvfs){
      .block_size = s.f_bsize,
      .fragment_size = s.f_frsize,
      .blocks = s.f_blocks,
      .blocks_free = s.f_bfree,
      .blocks_available = s.f_bavail,
      .files = s.f_files,
      .files_free = s.f_ffree,
      .files_available = s.f_favail,
      .name_max = s.f_namemax,
  };

  return 0;
}
