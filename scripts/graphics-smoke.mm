// SPDX-License-Identifier: Apache-2.0
// Host-only test: Metal GPU draw -> ANGLE EGLImage -> ES FBO -> CPU RGBA.
// Deliberately waits for the Metal producer; this does not prove live VM synchronization.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <algorithm>
#include <array>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <string>
#include <vector>

static void require(bool value, const char *message) {
    if (!value) throw std::runtime_error(message);
}

static void trace(const char *stage) {
    fprintf(stderr, "{\"stage\":\"%s\"}\n", stage);
    fflush(stderr);
}

template <typename T> static T entry(const char *name) {
    auto result = reinterpret_cast<T>(eglGetProcAddress(name));
    require(result != nullptr, name);
    return result;
}

static std::array<uint8_t, 4> pixel(unsigned x, unsigned y, unsigned width, unsigned height) {
    if (x == width / 2 || y == height / 2) return {17,136,204,255};
    if (y < height / 2) return x < width / 2 ? std::array<uint8_t,4>{255,0,0,255} : std::array<uint8_t,4>{0,255,0,255};
    return x < width / 2 ? std::array<uint8_t,4>{0,0,255,255} : std::array<uint8_t,4>{255,255,255,255};
}

int main(int argc, char **argv) {
    @autoreleasepool {
        try {
            std::vector<bool> modes = {false, true};
            bool usePackBuffer = true;
            for (int argument = 1; argument < argc; ++argument) {
                if (std::strcmp(argv[argument], "--pbuffer-only") == 0) modes = {true};
                else if (std::strcmp(argv[argument], "--surfaceless-only") == 0) modes = {false};
                else if (std::strcmp(argv[argument], "--direct-readback") == 0) usePackBuffer = false;
                else require(false, "Usage: graphics-smoke [--pbuffer-only|--surfaceless-only] [--direct-readback]");
            }
            trace("egl_dispatch");
            auto getDisplay = entry<PFNEGLGETPLATFORMDISPLAYEXTPROC>("eglGetPlatformDisplayEXT");
            const EGLint displayAttributes[] = {EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE};
            EGLDisplay display = getDisplay(EGL_PLATFORM_ANGLE_ANGLE, nullptr, displayAttributes);
            require(display != EGL_NO_DISPLAY, "Metal EGL display unavailable");
            trace("egl_initialize");
            EGLint major, minor;
            require(eglInitialize(display, &major, &minor), "eglInitialize");
            require(eglBindAPI(EGL_OPENGL_ES_API), "eglBindAPI");
            trace("metal_device_query");
            const char *extensions = eglQueryString(display, EGL_EXTENSIONS);
            require(extensions && strstr(extensions, "EGL_ANGLE_metal_texture_client_buffer"), "Metal texture import extension absent");
            auto queryDisplay = entry<PFNEGLQUERYDISPLAYATTRIBEXTPROC>("eglQueryDisplayAttribEXT");
            auto queryDevice = entry<PFNEGLQUERYDEVICEATTRIBEXTPROC>("eglQueryDeviceAttribEXT");
            EGLAttrib deviceValue = 0, metalValue = 0;
            require(queryDisplay(display, EGL_DEVICE_EXT, &deviceValue), "Query EGL device");
            require(queryDevice(reinterpret_cast<EGLDeviceEXT>(deviceValue), EGL_METAL_DEVICE_ANGLE, &metalValue), "Query ANGLE Metal device");
            id<MTLDevice> metal = (__bridge id<MTLDevice>)(reinterpret_cast<void *>(metalValue));
            require(metal != nil, "ANGLE Metal device is nil");
            trace("egl_context");

            const EGLint configAttributes[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR,
                EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE};
            EGLConfig config;
            EGLint count = 0;
            require(eglChooseConfig(display, configAttributes, &config, 1, &count) && count == 1, "ES3 pbuffer config");
            const EGLint contextAttributes[] = {EGL_CONTEXT_CLIENT_VERSION,3,EGL_NONE};
            EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttributes);
            require(context != EGL_NO_CONTEXT, "ES3 context");
            trace("gl_dispatch");
            auto createImage = entry<PFNEGLCREATEIMAGEKHRPROC>("eglCreateImageKHR");
            auto destroyImage = entry<PFNEGLDESTROYIMAGEKHRPROC>("eglDestroyImageKHR");
            auto bindImage = entry<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>("glEGLImageTargetTexture2DOES");
            // WebKit's GLES dylib restricts direct-link clients. Use EGL dispatch,
            // like libepoxy, without impersonating a framework client.
            auto glGenTextures = entry<decltype(&::glGenTextures)>("glGenTextures");
            auto glBindTexture = entry<decltype(&::glBindTexture)>("glBindTexture");
            auto glTexParameteri = entry<decltype(&::glTexParameteri)>("glTexParameteri");
            auto glGenFramebuffers = entry<decltype(&::glGenFramebuffers)>("glGenFramebuffers");
            auto glBindFramebuffer = entry<decltype(&::glBindFramebuffer)>("glBindFramebuffer");
            auto glFramebufferTexture2D = entry<decltype(&::glFramebufferTexture2D)>("glFramebufferTexture2D");
            auto glCheckFramebufferStatus = entry<decltype(&::glCheckFramebufferStatus)>("glCheckFramebufferStatus");
            auto glPixelStorei = entry<decltype(&::glPixelStorei)>("glPixelStorei");
            auto glReadPixels = entry<decltype(&::glReadPixels)>("glReadPixels");
            auto glGetError = entry<decltype(&::glGetError)>("glGetError");
            auto glDeleteFramebuffers = entry<decltype(&::glDeleteFramebuffers)>("glDeleteFramebuffers");
            auto glDeleteTextures = entry<decltype(&::glDeleteTextures)>("glDeleteTextures");
            auto glGenBuffers = entry<decltype(&::glGenBuffers)>("glGenBuffers");
            auto glBindBuffer = entry<decltype(&::glBindBuffer)>("glBindBuffer");
            auto glBufferData = entry<decltype(&::glBufferData)>("glBufferData");
            auto glMapBufferRange = entry<decltype(&::glMapBufferRange)>("glMapBufferRange");
            auto glUnmapBuffer = entry<decltype(&::glUnmapBuffer)>("glUnmapBuffer");
            auto glDeleteBuffers = entry<decltype(&::glDeleteBuffers)>("glDeleteBuffers");

            NSString *shader = @"#include <metal_stdlib>\nusing namespace metal;\n"
                "vertex float4 vs(uint i [[vertex_id]]) { float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\n"
                "fragment float4 fs(float4 p [[position]],constant uint2 &size [[buffer(0)]]) { if(uint(p.x)==size.x/2 || uint(p.y)==size.y/2) return float4(17.0f/255.0f,136.0f/255.0f,204.0f/255.0f,1); bool left=p.x<float(size.x/2); bool top=p.y<float(size.y/2); if(top) return left?float4(1,0,0,1):float4(0,1,0,1); return left?float4(0,0,1,1):float4(1,1,1,1); }";
            NSError *error = nil;
            trace("metal_shader_compile");
            id<MTLLibrary> library = [metal newLibraryWithSource:shader options:nil error:&error];
            require(library != nil, error ? error.localizedDescription.UTF8String : "Metal shader compilation");
            MTLRenderPipelineDescriptor *pipelineDescriptor = [MTLRenderPipelineDescriptor new];
            pipelineDescriptor.vertexFunction = [library newFunctionWithName:@"vs"];
            pipelineDescriptor.fragmentFunction = [library newFunctionWithName:@"fs"];
            pipelineDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            id<MTLRenderPipelineState> pipeline = [metal newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&error];
            require(pipeline != nil, "Metal pipeline creation");
            id<MTLCommandQueue> queue = [metal newCommandQueue];
            require(queue != nil, "Metal queue");
            trace("metal_pipeline_ready");
            int establishedOrientation = -1;
            unsigned trials = 0;
            for (bool pbuffer : modes) {
                if (!pbuffer) require(strstr(extensions, "EGL_KHR_surfaceless_context"), "Surfaceless extension absent");
                const EGLint pbufferAttributes[] = {EGL_WIDTH,1,EGL_HEIGHT,1,EGL_NONE};
                EGLSurface surface = pbuffer ? eglCreatePbufferSurface(display, config, pbufferAttributes) : EGL_NO_SURFACE;
                require(!pbuffer || surface != EGL_NO_SURFACE, "Create fallback pbuffer");
                require(eglMakeCurrent(display, surface, surface, context), "Make offscreen context current");
                for (bool linear : {false, true}) {
                    // Reuse the context while growing and shrinking the framebuffer.
                    for (const auto &size : {std::array<unsigned,2>{800,600}, std::array<unsigned,2>{1920,1080},
                                           std::array<unsigned,2>{803,607}, std::array<unsigned,2>{800,600}}) {
                        const unsigned width = size[0], height = size[1];
                        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
                        descriptor.storageMode = MTLStorageModePrivate;
                        descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
                        id<MTLTexture> texture = [metal newTextureWithDescriptor:descriptor];
                        require(texture != nil, "Metal source texture");
                        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
                        pass.colorAttachments[0].texture = texture;
                        pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
                        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                        id<MTLCommandBuffer> buffer = [queue commandBuffer];
                        id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
                        [encoder setRenderPipelineState:pipeline];
                        [encoder setViewport:MTLViewport{0,0,static_cast<double>(width),static_cast<double>(height),0,1}];
                        [encoder setFragmentBytes:size.data() length:sizeof(unsigned)*2 atIndex:0];
                        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                        [encoder endEncoding];
                        [buffer commit];
                        [buffer waitUntilCompleted];
                        require(buffer.status == MTLCommandBufferStatusCompleted, "Metal producer completion");
                        trace("metal_draw_completed");

                        id<MTLTexture> importedTexture = texture;
                        if (linear) {
                            // The renderer's cross-process path wraps shared memory in a
                            // linear MTLBuffer texture. Test that layout too, but this is
                            // a same-process buffer, not validation of cross-process IPC.
                            const NSUInteger alignment = [metal minimumLinearTextureAlignmentForPixelFormat:descriptor.pixelFormat];
                            require(alignment > 0, "Linear texture alignment unavailable");
                            const NSUInteger rowPitch = (width * 4 + alignment - 1) / alignment * alignment;
                            id<MTLBuffer> backing = [metal newBufferWithLength:rowPitch * height options:MTLResourceStorageModeShared];
                            require(backing != nil, "Linear texture backing allocation");
                            descriptor.storageMode = MTLStorageModeShared;
                            descriptor.usage = MTLTextureUsageShaderRead;
                            importedTexture = [backing newTextureWithDescriptor:descriptor offset:0 bytesPerRow:rowPitch];
                            require(importedTexture != nil, "Linear shared source texture");
                            id<MTLCommandBuffer> copy = [queue commandBuffer];
                            id<MTLBlitCommandEncoder> blit = [copy blitCommandEncoder];
                            [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0
                                sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(width,height,1)
                                toTexture:importedTexture destinationSlice:0 destinationLevel:0
                                destinationOrigin:MTLOriginMake(0,0,0)];
                            [blit endEncoding];
                            [copy commit];
                            [copy waitUntilCompleted];
                            require(copy.status == MTLCommandBufferStatusCompleted, "Linear texture producer completion");
                            trace("metal_linear_copy_completed");
                        }
                        EGLImageKHR image = createImage(display, EGL_NO_CONTEXT, EGL_METAL_TEXTURE_ANGLE,
                            (__bridge EGLClientBuffer)importedTexture, nullptr);
                        require(image != EGL_NO_IMAGE_KHR, "Import native Metal texture");
                        trace("metal_image_imported");
                        GLuint glTexture = 0, framebuffer = 0;
                        glGenTextures(1, &glTexture);
                        trace("gl_texture_created");
                        glBindTexture(GL_TEXTURE_2D, glTexture);
                        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
                        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
                        bindImage(GL_TEXTURE_2D, image);
                        trace("gl_image_bound");
                        glGenFramebuffers(1, &framebuffer);
                        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
                        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, glTexture, 0);
                        require(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "Imported FBO incomplete");
                        trace("gl_fbo_complete");
                        std::vector<uint8_t> rgba(static_cast<size_t>(width)*height*4);
                        glPixelStorei(GL_PACK_ALIGNMENT, 1);
                        if (usePackBuffer) {
                            // Imported private Metal textures cannot use Texture::getBytes(),
                            // whose source precondition is CPU-accessible storage. ANGLE's
                            // FramebufferMtl::readPixelsToPBO instead performs a GPU blit or
                            // compute conversion, then BufferMtl::mapRange synchronizes it.
                            GLuint packBuffer = 0;
                            glGenBuffers(1, &packBuffer);
                            glBindBuffer(GL_PIXEL_PACK_BUFFER, packBuffer);
                            glBufferData(GL_PIXEL_PACK_BUFFER, static_cast<GLsizeiptr>(rgba.size()), nullptr, GL_STREAM_READ);
                            require(glGetError() == GL_NO_ERROR, "Allocate bounded readback buffer");
                            glReadPixels(0,0,width,height,GL_RGBA,GL_UNSIGNED_BYTE,nullptr);
                            require(glGetError() == GL_NO_ERROR, "GPU readback error");
                            trace("gl_pbo_transfer_issued");
                            const void *mapped = glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0,
                                static_cast<GLsizeiptr>(rgba.size()), GL_MAP_READ_BIT);
                            require(mapped != nullptr, "Map readback buffer");
                            std::memcpy(rgba.data(), mapped, rgba.size());
                            require(glUnmapBuffer(GL_PIXEL_PACK_BUFFER), "Unmap readback buffer");
                            glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
                            glDeleteBuffers(1, &packBuffer);
                        } else {
                            // Diagnostic only: this pinned ANGLE crashes on private imported
                            // textures in the direct CPU route, on this test host.
                            glReadPixels(0,0,width,height,GL_RGBA,GL_UNSIGNED_BYTE,rgba.data());
                        }
                        trace("gl_readback_completed");
                        require(glGetError() == GL_NO_ERROR, "Readback GL error");
                        std::array<size_t,2> mismatches = {0,0};
                        for (unsigned y=0;y<height;y++) for(unsigned x=0;x<width;x++) {
                            const uint8_t *actual=&rgba[(static_cast<size_t>(y)*width+x)*4];
                            for(unsigned flip=0;flip<2;flip++) {
                                auto expected=pixel(x,flip?height-1-y:y,width,height);
                                if (!std::equal(expected.begin(),expected.end(),actual)) mismatches[flip]++;
                            }
                        }
                        require((mismatches[0]==0) != (mismatches[1]==0), "Pixel colors/orientation mismatch");
                        int orientation=mismatches[0]==0?0:1;
                        require(establishedOrientation<0 || establishedOrientation==orientation, "Orientation changed between modes");
                        establishedOrientation=orientation;
                        printf("{\"mode\":\"%s\",\"storage\":\"%s\",\"readback\":\"%s\",\"width\":%u,\"height\":%u,\"matched_pixels\":%u,\"rgba_bytes\":%zu,\"readback_row_zero\":\"metal_%s\",\"producer_waited\":true}\n",
                            pbuffer?"pbuffer":"surfaceless",linear?"shared_linear":"private",usePackBuffer?"pbo":"direct",width,height,width*height,rgba.size(),orientation?"bottom":"top");
                        fflush(stdout);
                        glBindFramebuffer(GL_FRAMEBUFFER,0);
                        glDeleteFramebuffers(1,&framebuffer);
                        glDeleteTextures(1,&glTexture);
                        require(destroyImage(display,image),"Destroy EGL image");
                        trials++;
                    }
                }
                require(eglMakeCurrent(display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT),"Release current context");
                if(pbuffer) require(eglDestroySurface(display,surface),"Destroy pbuffer");
            }
            require(eglDestroyContext(display,context),"Destroy context");
            require(eglTerminate(display),"Terminate EGL");
            printf("{\"result\":\"pass\",\"trials\":%u,\"guest_or_vm_started\":false}\n",trials);
            return EXIT_SUCCESS;
        } catch(const std::exception &error) {
            fprintf(stderr,"Graphics offscreen smoke failed: %s\n",error.what());
            return EXIT_FAILURE;
        }
    }
}
