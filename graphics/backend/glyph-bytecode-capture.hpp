#pragma once

// Optional QA instrumentation. Never enable this in the production payload.
// The caller already computed the shader hash; this captures only the two
// immutable programs observed in the incomplete Explorer header.
#if defined(DXMT_NATIVE) && defined(__APPLE__) && defined(PERP_DIAGNOSTIC_GLYPH_DXBC)
#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <fcntl.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include "log/log.hpp"
#include "sha1/sha1_util.hpp"

namespace dxmt {
inline void captureGlyphBytecode(const Sha1Digest &digest, const void *bytes, size_t length) {
  if (!bytes || !length || length > 1024 * 1024)
    return;
  const char *directory = std::getenv("PERP_CAPTURE_GLYPH_DXBC");
  if (!directory || directory[0] != '/')
    return;
  const auto hash = digest.string();
  if (hash != "bf686d2421523da35bf96a28103aaa80ee93be18" &&
      hash != "6455f5c65380e530486c8965ced8e662623c11df")
    return;
  struct stat status;
  if (lstat(directory, &status) || !S_ISDIR(status.st_mode) ||
      status.st_uid != getuid() || (status.st_mode & 0077))
    return;
  const std::string path = std::string(directory) + "/" + hash + ".cso";
  const auto started = std::chrono::steady_clock::now();
  const int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (fd < 0)
    return;
  size_t written = 0;
  while (written < length) {
    const auto count = write(fd, static_cast<const char *>(bytes) + written, length - written);
    if (count < 0 && errno == EINTR)
      continue;
    if (count <= 0)
      break;
    written += static_cast<size_t>(count);
  }
  const bool complete = close(fd) == 0 && written == length;
  if (!complete) {
    // O_EXCL above established that this invocation created the incomplete file.
    unlink(path.c_str());
    WARN("PERP_GLYPH_DXBC_CAPTURE incomplete: ", hash);
    return;
  }
  const auto micros = std::chrono::duration_cast<std::chrono::microseconds>(
      std::chrono::steady_clock::now() - started).count();
  WARN("PERP_GLYPH_DXBC_CAPTURE ", hash, " bytes=", length, " writeMicroseconds=", micros);
}
} // namespace dxmt
#endif
