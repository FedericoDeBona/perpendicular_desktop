// SPDX-License-Identifier: MIT
// Independent Metal/ANGLE consumer of a DXMT shm texture and real event fd.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <array>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include "wire.h"

static std::atomic<unsigned> mappings_released;
template<class T> static T entry(const char *name) {
    auto value=reinterpret_cast<T>(eglGetProcAddress(name)); check(value!=nullptr,name); return value;
}
int main(int argc,char **argv) {
    @autoreleasepool {
        try {
            check(argc==2,"Usage: consumer inherited-socket-fd");
            int socket=std::atoi(argv[1]); configure_socket(socket);
            auto platform=entry<PFNEGLGETPLATFORMDISPLAYEXTPROC>("eglGetPlatformDisplayEXT");
            EGLint attributes[]={EGL_PLATFORM_ANGLE_TYPE_ANGLE,EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,EGL_NONE};
            EGLDisplay display=platform(EGL_PLATFORM_ANGLE_ANGLE,nullptr,attributes);
            EGLint major,minor,count; check(display!=EGL_NO_DISPLAY && eglInitialize(display,&major,&minor),"Initialize Metal EGL");
            check(eglBindAPI(EGL_OPENGL_ES_API),"Bind ES API");
            EGLint config_attributes[]={EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT_KHR,
                EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE};
            EGLConfig config;
            check(eglChooseConfig(display,config_attributes,&config,1,&count) && count==1,"ES3 config");
            EGLint context_attributes[]={EGL_CONTEXT_CLIENT_VERSION,3,EGL_NONE};
            EGLContext context=eglCreateContext(display,config,EGL_NO_CONTEXT,context_attributes);
            EGLint surface_attributes[]={EGL_WIDTH,1,EGL_HEIGHT,1,EGL_NONE};
            EGLSurface surface=eglCreatePbufferSurface(display,config,surface_attributes);
            check(context!=EGL_NO_CONTEXT && surface!=EGL_NO_SURFACE && eglMakeCurrent(display,surface,surface,context),"Make pbuffer current");
            EGLAttrib egl_device=0,metal_device=0;
            check(entry<PFNEGLQUERYDISPLAYATTRIBEXTPROC>("eglQueryDisplayAttribEXT")(display,EGL_DEVICE_EXT,&egl_device),"EGL device");
            check(entry<PFNEGLQUERYDEVICEATTRIBEXTPROC>("eglQueryDeviceAttribEXT")(
                reinterpret_cast<EGLDeviceEXT>(egl_device),EGL_METAL_DEVICE_ANGLE,&metal_device),"Metal device");
            id<MTLDevice> metal=(__bridge id<MTLDevice>)reinterpret_cast<void *>(metal_device);
            check(metal!=nil,"Missing Metal device");
            auto create_image=entry<PFNEGLCREATEIMAGEKHRPROC>("eglCreateImageKHR");
            auto destroy_image=entry<PFNEGLDESTROYIMAGEKHRPROC>("eglDestroyImageKHR");
            auto bind_image=entry<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>("glEGLImageTargetTexture2DOES");
#define GL_ENTRY(name) auto name=entry<decltype(&::name)>(#name)
            GL_ENTRY(glGenTextures); GL_ENTRY(glBindTexture); GL_ENTRY(glTexParameteri);
            GL_ENTRY(glGenFramebuffers); GL_ENTRY(glBindFramebuffer); GL_ENTRY(glFramebufferTexture2D);
            GL_ENTRY(glCheckFramebufferStatus); GL_ENTRY(glGenBuffers); GL_ENTRY(glBindBuffer);
            GL_ENTRY(glBufferData); GL_ENTRY(glPixelStorei); GL_ENTRY(glReadPixels);
            GL_ENTRY(glGetError); GL_ENTRY(glMapBufferRange); GL_ENTRY(glUnmapBuffer);
            GL_ENTRY(glDeleteBuffers); GL_ENTRY(glDeleteFramebuffers); GL_ENTRY(glDeleteTextures); GL_ENTRY(glFinish);
#undef GL_ENTRY
            uint64_t pixels=0;
            for(unsigned sequence=1;sequence<=8;sequence++) {
                @autoreleasepool {
                    int fds[]={-1,-1}; Frame frame=receive_frame(socket,fds);
                    auto &desc=frame.texture; unsigned width=desc.meta.width,height=desc.meta.height;
                    check(frame.sequence==sequence && frame.flags<=1 &&
                        dxn_shared_check(&desc,DXN_SHARED_TEXTURE_MAGIC,sizeof(desc)),"Frame descriptor/version");
                    check(width>0 && height>0 && width<=4096 && height<=4096 && uint64_t(width)*height<=8*1024*1024 &&
                        desc.meta.dxgi_format==87 && desc.meta.mip_levels==1 && desc.meta.array_size==1 &&
                        desc.meta.sample_count==1 && desc.meta.sample_quality==0 && desc.plane_count==1 &&
                        desc.reserved==0 && desc.drm_modifier==0 && desc.planes[0].offset==0,"Unsupported bounded texture layout");
                    uint64_t pitch=desc.planes[0].pitch;
                    check(pitch>=uint64_t(width)*4 && pitch<=65536 && desc.size==pitch*height,"Texture pitch/size");
                    size_t page=size_t(sysconf(_SC_PAGESIZE));
                    check(page && !(page&(page-1)) && desc.size<=64*1024*1024,"Bounded shared allocation");
                    size_t mapped_bytes=(size_t(desc.size)+page-1)&~(page-1);
                    struct stat st{};
                    check(fstat(fds[0],&st)==0,"SHM fstat");
                    fprintf(stderr,"SHM descriptor: mode=0%o file_bytes=%lld logical=%llu mapped=%zu pitch=%llu\n",
                        st.st_mode,st.st_size,desc.size,mapped_bytes,pitch);
                    // Darwin POSIX shm fstat reports permission bits with no
                    // S_IFMT type (observed 0600); ordinary regular files also
                    // suffice for this bounded, private same-host fixture.
                    check((S_ISREG(st.st_mode) || (st.st_mode&S_IFMT)==0) && st.st_size>=0 &&
                        uint64_t(st.st_size)>=mapped_bytes && st.st_size<=64*1024*1024,"SHM fd extent/type");
                    // This FD is a backend-created event, not an arbitrary
                    // readiness guess or a consumer-side glFinish.
                    check(wait_fd(fds[1],25)==0,"Producer token unexpectedly ready before Signal");
                    notify(socket,'S');
                    short ready=wait_fd(fds[1],5000);
                    check((ready&POLLIN) && !(ready&(POLLERR|POLLHUP|POLLNVAL)),"Producer completion fd failed or timed out");
                    close(fds[1]);
                    control(socket,'O'); // original is now magenta; snapshot must survive.
                    void *mapping=mmap(nullptr,mapped_bytes,PROT_READ|PROT_WRITE,MAP_SHARED,fds[0],0);
                    check(mapping!=MAP_FAILED,"Map producer SHM"); close(fds[0]);
                    id<MTLBuffer> backing=[metal newBufferWithBytesNoCopy:mapping length:mapped_bytes
                        options:MTLResourceStorageModeShared deallocator:^(void *pointer,NSUInteger length) {
                            munmap(pointer,length); mappings_released++;
                        }];
                    if(!backing) { munmap(mapping,mapped_bytes); check(false,"Wrap imported SHM"); }
                    MTLTextureDescriptor *texture_desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                        width:width height:height mipmapped:NO];
                    texture_desc.storageMode=MTLStorageModeShared; texture_desc.usage=MTLTextureUsageShaderRead;
                    check(pitch%[metal minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatBGRA8Unorm]==0,"Metal row alignment");
                    id<MTLTexture> texture=[backing newTextureWithDescriptor:texture_desc offset:0 bytesPerRow:pitch];
                    check(texture!=nil,"Import DXMT shared texture layout");
                    EGLImageKHR image=create_image(display,EGL_NO_CONTEXT,EGL_METAL_TEXTURE_ANGLE,(__bridge EGLClientBuffer)texture,nullptr);
                    check(image!=EGL_NO_IMAGE_KHR,"Import native shared texture EGLImage");
                    GLuint tex=0,fb=0,pack=0;
                    glGenTextures(1,&tex); glBindTexture(GL_TEXTURE_2D,tex);
                    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST); glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
                    bind_image(GL_TEXTURE_2D,image);
                    glGenFramebuffers(1,&fb); glBindFramebuffer(GL_FRAMEBUFFER,fb);
                    glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,tex,0);
                    check(glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE,"Imported shared FBO complete");
                    std::vector<uint8_t> rgba(size_t(width)*height*4);
                    glGenBuffers(1,&pack); glBindBuffer(GL_PIXEL_PACK_BUFFER,pack);
                    glBufferData(GL_PIXEL_PACK_BUFFER,rgba.size(),nullptr,GL_STREAM_READ); glPixelStorei(GL_PACK_ALIGNMENT,1);
                    glReadPixels(0,0,width,height,GL_RGBA,GL_UNSIGNED_BYTE,nullptr);
                    check(glGetError()==GL_NO_ERROR,"PBO read issue");
                    void *mapped=glMapBufferRange(GL_PIXEL_PACK_BUFFER,0,rgba.size(),GL_MAP_READ_BIT);
                    check(mapped!=nullptr,"Map completed consumer GPU read");
                    std::memcpy(rgba.data(),mapped,rgba.size()); check(glUnmapBuffer(GL_PIXEL_PACK_BUFFER),"Unmap PBO");
                    const std::array<uint8_t,4> quadrants[]={{255,0,0,255},{0,255,0,255},{0,0,255,255},{255,255,255,255}};
                    for(unsigned y=0;y<height;y++) for(unsigned x=0;x<width;x++) {
                        unsigned quadrant=(x>=width/2)+(y>=height/2)*2;
                        auto expected=(x==width/2 || y==height/2) ? std::array<uint8_t,4>{17,136,204,255}
                            : quadrants[frame.flags?3-quadrant:quadrant];
                        check(!std::memcmp(&rgba[(size_t(y)*width+x)*4],expected.data(),4),"DXMT cross-process pixel mismatch");
                    }
                    glBindBuffer(GL_PIXEL_PACK_BUFFER,0); glBindFramebuffer(GL_FRAMEBUFFER,0);
                    glDeleteBuffers(1,&pack); glDeleteFramebuffers(1,&fb); glDeleteTextures(1,&tex);
                    check(destroy_image(display,image),"Destroy imported EGLImage");
                    glFinish(); check(glGetError()==GL_NO_ERROR,"Consumer GPU completion");
                    texture=nil; backing=nil;
                    pixels+=uint64_t(width)*height;
                    // Producer may rewrite/release only after this ACK.
                    notify(socket,'A');
                    printf("{\"consumer_frame\":%u,\"width\":%u,\"height\":%u,\"pixels\":%u,\"producer_fd_observed\":true}\n",sequence,width,height,width*height);
                    fflush(stdout);
                }
            }
            control(socket,'E'); close(socket);
            check(eglMakeCurrent(display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT),"Unbind consumer");
            check(eglDestroyContext(display,context) && eglDestroySurface(display,surface) && eglTerminate(display),"Destroy consumer context");
            check(mappings_released==8,"SHM mappings not all released");
            printf("{\"result\":\"pass\",\"frames\":8,\"exact_pixels\":%llu,\"mappings_released\":%u}\n",pixels,mappings_released.load());
            return 0;
        } catch(const std::exception &error) {
            fprintf(stderr,"DXMT consumer failed: %s\n",error.what()); return 1;
        }
    }
}
