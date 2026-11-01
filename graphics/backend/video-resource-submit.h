/* Versioned, pointer-free input for D3D11 Video DecoderExtension.
 * ARM64 Windows and macOS use little endian uint32_t fields.
 * SPDX-License-Identifier: MIT
 */
#ifndef PERP_VIDEO_RESOURCE_SUBMIT_H
#define PERP_VIDEO_RESOURCE_SUBMIT_H
#include <stdint.h>
#define PERP_VIDEO_RESOURCE_VERSION 1u
#define PERP_VIDEO_RESOURCE_QUERY 0x31565051u
#define PERP_VIDEO_RESOURCE_SUBMIT 0x31565053u
#define PERP_VIDEO_RESOURCE_FINISH 0x31565046u
#define PERP_VIDEO_MAX_BUFFERS 3u
#define PERP_VIDEO_MAX_BITSTREAM (16u * 1024u * 1024u)
#define PERP_VIDEO_MAX_METADATA (64u * 1024u)
struct perp_video_resource_header {
  uint32_t version;
  uint32_t count;
};
struct perp_video_resource_buffer {
  uint32_t type; /* public D3D11_VIDEO_DECODER_BUFFER_TYPE, not DDI enum */
  uint32_t resource_index;
  uint32_t offset;
  uint32_t size;
};
#ifdef __cplusplus
static_assert(sizeof(perp_video_resource_header) == 8);
static_assert(sizeof(perp_video_resource_buffer) == 16);
#else
_Static_assert(sizeof(struct perp_video_resource_header) == 8, "video header ABI");
_Static_assert(sizeof(struct perp_video_resource_buffer) == 16, "video buffer ABI");
#endif
#endif
