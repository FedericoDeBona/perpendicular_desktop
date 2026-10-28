/* A bounded WGL shader/readback check. No installation or user documents.
 * Pass an explicit opengl32.dll, optionally --present, --msaa or --atlas.
 * MSAA resolves a four-sample target, reproducing the M1 sampler-name failure. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <GL/gl.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

typedef HGLRC (WINAPI *CreateContext)(HDC);
typedef BOOL (WINAPI *MakeCurrent)(HDC,HGLRC);
typedef BOOL (WINAPI *DeleteContext)(HGLRC);
typedef PROC (WINAPI *GetProc)(LPCSTR);
typedef int (WINAPI *ChooseFormat)(HDC,const PIXELFORMATDESCRIPTOR *);
typedef BOOL (WINAPI *SetFormat)(HDC,int,const PIXELFORMATDESCRIPTOR *);
typedef BOOL (WINAPI *Swap)(HDC);
#define GLPROC(name,ret,...) ret (APIENTRY *p##name)(__VA_ARGS__)=(void *)GetProcAddress(library,#name)
#define EXTPROC(name,ret,...) ret (APIENTRY *p##name)(__VA_ARGS__)=(void *)get(#name)

static void print_location(const char *label, void *address)
{
    HMODULE module=NULL; char path[MAX_PATH]={0};
    if(GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                         (LPCSTR)address,&module)) {
        GetModuleFileNameA(module,path,sizeof(path));
        const char *name=strrchr(path,'\\');
        printf("%s=%s+0x%llx\n",label,name?name+1:path,
               (unsigned long long)((uintptr_t)address-(uintptr_t)module));
    } else printf("%s=%p\n",label,address);
}

static LONG WINAPI report_exception(EXCEPTION_POINTERS *exception)
{
    printf("Unhandled exception=0x%08lx\n",exception->ExceptionRecord->ExceptionCode);
    print_location("fault",exception->ExceptionRecord->ExceptionAddress);
#if defined(_M_ARM64)
    print_location("return",(void *)(uintptr_t)exception->ContextRecord->Lr);
#endif
    fflush(stdout);
    return EXCEPTION_EXECUTE_HANDLER;
}

int main(int argc,char **argv)
{
    if(argc<2||argc>3||(argc==3&&strcmp(argv[2],"--present")&&strcmp(argv[2],"--msaa")&&strcmp(argv[2],"--atlas")))return 2;
    const int present=argc==3&&!strcmp(argv[2],"--present");
    const int msaa=argc==3&&!strcmp(argv[2],"--msaa");
    const int atlas=argc==3&&!strcmp(argv[2],"--atlas");
    int atlas_ok=1;
    SetUnhandledExceptionFilter(report_exception);
    setvbuf(stdout,NULL,_IONBF,0);
    HMODULE library=LoadLibraryExA(argv[1],NULL,LOAD_WITH_ALTERED_SEARCH_PATH);
    if(!library){printf("LoadLibrary=%lu\n",GetLastError());return 1;}
    CreateContext create=(void *)GetProcAddress(library,"wglCreateContext");
    MakeCurrent current=(void *)GetProcAddress(library,"wglMakeCurrent");
    DeleteContext destroy=(void *)GetProcAddress(library,"wglDeleteContext");
    GetProc get=(void *)GetProcAddress(library,"wglGetProcAddress");
    ChooseFormat choose=(void *)GetProcAddress(library,"wglChoosePixelFormat");
    SetFormat format=(void *)GetProcAddress(library,"wglSetPixelFormat");
    Swap swap=(void *)GetProcAddress(library,"wglSwapBuffers");
    if(!create||!current||!destroy||!get||!choose||!format){puts("Missing WGL exports");FreeLibrary(library);return 1;}
    WNDCLASSA wc={0};wc.style=CS_OWNDC;wc.lpfnWndProc=DefWindowProcA;wc.hInstance=GetModuleHandleA(NULL);wc.lpszClassName="PerpendicularWGLProbe";
    if(!RegisterClassA(&wc)){FreeLibrary(library);return 1;}
    HWND window=CreateWindowA(wc.lpszClassName,"Perpendicular WGL probe",WS_POPUP,0,0,128,128,NULL,NULL,wc.hInstance,NULL);
    HDC dc=window?GetDC(window):NULL;HGLRC context=NULL;int success=0;
    if(present&&window){ShowWindow(window,SW_SHOWNOACTIVATE);UpdateWindow(window);}
    PIXELFORMATDESCRIPTOR pf={0};pf.nSize=sizeof(pf);pf.nVersion=1;pf.dwFlags=PFD_DRAW_TO_WINDOW|PFD_SUPPORT_OPENGL|PFD_DOUBLEBUFFER;pf.iPixelType=PFD_TYPE_RGBA;pf.cColorBits=32;pf.cDepthBits=24;pf.cStencilBits=8;
    int selected=dc?choose(dc,&pf):0;
    if(!selected||!format(dc,selected,&pf)||(context=create(dc))==NULL||!current(dc,context)){printf("WGL context failed=%lu\n",GetLastError());goto done;}
    GLPROC(glGetString,const GLubyte *,GLenum);
    GLPROC(glViewport,void,GLint,GLint,GLsizei,GLsizei);
    GLPROC(glClearColor,void,GLclampf,GLclampf,GLclampf,GLclampf);
    GLPROC(glClear,void,GLbitfield);
    GLPROC(glDrawArrays,void,GLenum,GLint,GLsizei);
    GLPROC(glFinish,void,void);
    GLPROC(glReadPixels,void,GLint,GLint,GLsizei,GLsizei,GLenum,GLenum,void *);
    GLPROC(glGetError,GLenum,void);
    GLPROC(glEnable,void,GLenum);
    GLPROC(glGetIntegerv,void,GLenum,GLint *);
    if(!pglGetString||!pglViewport||!pglClearColor||!pglClear||!pglDrawArrays||!pglFinish||!pglReadPixels||!pglGetError)goto done;
    const char *renderer=(const char *)pglGetString(GL_RENDERER);
    printf("GL_VENDOR=%s\nGL_RENDERER=%s\nGL_VERSION=%s\n",pglGetString(GL_VENDOR),renderer,pglGetString(GL_VERSION));
    GLenum initial_error=pglGetError();printf("GL_ERROR after context=0x%x\n",initial_error);
    GLint depth_bits=0,stencil_bits=0;
    if(!pglEnable||!pglGetIntegerv)goto done;
    pglGetIntegerv(GL_DEPTH_BITS,&depth_bits);pglGetIntegerv(GL_STENCIL_BITS,&stencil_bits);
    printf("Depth bits=%d; stencil bits=%d\n",depth_bits,stencil_bits);
    if(depth_bits<24||stencil_bits<8)goto done;
    if(!renderer||!strstr(renderer,"zink")||!strstr(renderer,"Apple")){puts("Expected Apple GPU through Zink");goto done;}
    if(atlas){
    GLPROC(glGenTextures,void,GLsizei,GLuint *);
    GLPROC(glBindTexture,void,GLenum,GLuint);
    GLPROC(glTexParameteri,void,GLenum,GLenum,GLint);
    GLPROC(glPixelStorei,void,GLenum,GLint);
    GLPROC(glTexImage2D,void,GLenum,GLint,GLint,GLsizei,GLsizei,GLint,GLenum,GLenum,const void *);
    const size_t bytes=4096ull*6854*4;
    unsigned char *input=malloc(bytes),*output=malloc(bytes);
    if(!input||!output)goto done;
    for(size_t n=0;n<bytes/4;n++){input[n*4]=255;input[n*4+1]=255;input[n*4+2]=255;input[n*4+3]=(unsigned char)((n/4096+n%4096)%256);}
    GLuint tex;pglGenTextures(1,&tex);pglBindTexture(GL_TEXTURE_2D,tex);pglPixelStorei(GL_UNPACK_ALIGNMENT,1);
    pglTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);pglTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
    GLint maxtex=0;pglGetIntegerv(GL_MAX_TEXTURE_SIZE,&maxtex);printf("MAX_TEXTURE_SIZE=%d; bytes=%llu\n",maxtex,(unsigned long long)bytes);
    pglTexImage2D(GL_TEXTURE_2D,0,GL_RGBA,4096,6854,0,GL_RGBA,GL_UNSIGNED_BYTE,input);pglFinish();
    GLenum upload_error=pglGetError();printf("Atlas upload error=0x%x\n",upload_error);
    void (APIENTRY *gen_fbo)(GLsizei,GLuint *)=(void*)get("glGenFramebuffers");
    void (APIENTRY *bind_fbo)(GLenum,GLuint)=(void*)get("glBindFramebuffer");
    void (APIENTRY *attach_tex)(GLenum,GLenum,GLenum,GLuint,GLint)=(void*)get("glFramebufferTexture2D");
    GLenum (APIENTRY *check_fbo)(GLenum)=(void*)get("glCheckFramebufferStatus");
    if(!gen_fbo||!bind_fbo||!attach_tex||!check_fbo)goto done;
    GLuint atlas_fbo;gen_fbo(1,&atlas_fbo);bind_fbo(0x8d40,atlas_fbo);attach_tex(0x8d40,0x8ce0,GL_TEXTURE_2D,tex,0);
    printf("Atlas framebuffer=0x%x\n",check_fbo(0x8d40));
    memset(output,0xcd,bytes);
    for(unsigned row=0;row<6854;row+=128){unsigned rows=6854-row<128?6854-row:128;pglReadPixels(0,row,4096,rows,GL_RGBA,GL_UNSIGNED_BYTE,output+(size_t)row*4096*4);}
    pglFinish();bind_fbo(0x8d40,0);
    GLenum texture_read_error=pglGetError();size_t bad=0;while(bad<bytes&&input[bad]==output[bad])bad++;
    printf("Atlas readback error=0x%x; equal=%s; first_difference=%llu",texture_read_error,bad==bytes?"true":"false",(unsigned long long)bad);
    if(bad<bytes)printf("; expected=%u; actual=%u",input[bad],output[bad]);puts("");
    atlas_ok=!upload_error&&!texture_read_error&&bad==bytes;
    free(input);free(output);
    }
    EXTPROC(glCreateShader,GLuint,GLenum);
    EXTPROC(glShaderSource,void,GLuint,GLsizei,const char **,const GLint *);
    EXTPROC(glCompileShader,void,GLuint);
    EXTPROC(glGetShaderiv,void,GLuint,GLenum,GLint *);
    EXTPROC(glGetShaderInfoLog,void,GLuint,GLsizei,GLsizei *,char *);
    EXTPROC(glCreateProgram,GLuint,void);
    EXTPROC(glAttachShader,void,GLuint,GLuint);
    EXTPROC(glLinkProgram,void,GLuint);
    EXTPROC(glGetProgramiv,void,GLuint,GLenum,GLint *);
    EXTPROC(glUseProgram,void,GLuint);
    EXTPROC(glGetAttribLocation,GLint,GLuint,const char *);
    EXTPROC(glGetUniformLocation,GLint,GLuint,const char *);
    EXTPROC(glUniform4f,void,GLint,GLfloat,GLfloat,GLfloat,GLfloat);
    EXTPROC(glEnableVertexAttribArray,void,GLuint);
    EXTPROC(glVertexAttribPointer,void,GLuint,GLint,GLenum,GLboolean,GLsizei,const void *);
    EXTPROC(glGenBuffers,void,GLsizei,GLuint *);
    EXTPROC(glBindBuffer,void,GLenum,GLuint);
    EXTPROC(glBufferData,void,GLenum,ptrdiff_t,const void *,GLenum);
    if(!pglCreateShader||!pglShaderSource||!pglCompileShader||!pglGetShaderiv||!pglGetShaderInfoLog||!pglCreateProgram||!pglAttachShader||!pglLinkProgram||!pglGetProgramiv||!pglUseProgram||!pglGetAttribLocation||!pglEnableVertexAttribArray||!pglVertexAttribPointer||!pglGenBuffers||!pglBindBuffer||!pglBufferData){puts("Missing shader/VBO API");goto done;}
    if(!pglGetUniformLocation||!pglUniform4f)goto done;
    const char *source[2]={"attribute vec3 position; void main(){gl_Position=vec4(position,1.0);}",atlas?"uniform vec4 color; uniform sampler2D Texture; void main(){gl_FragColor=color*texture2D(Texture,vec2(0.2501220703,0.5000729501));}":"uniform vec4 color; void main(){gl_FragColor=color;}"};
    GLuint shader[2];
    for(int i=0;i<2;i++){
        shader[i]=pglCreateShader(i?0x8b30:0x8b31);pglShaderSource(shader[i],1,&source[i],NULL);pglCompileShader(shader[i]);
        GLint compiled=0;pglGetShaderiv(shader[i],0x8b81,&compiled);
        if(!compiled){char error[512]={0};pglGetShaderInfoLog(shader[i],511,NULL,error);printf("Shader failed: %s\n",error);goto done;}
    }
    GLuint program=pglCreateProgram();pglAttachShader(program,shader[0]);pglAttachShader(program,shader[1]);pglLinkProgram(program);
    GLint linked=0;pglGetProgramiv(program,0x8b82,&linked);if(!linked){puts("Program link failed");goto done;}
    pglUseProgram(program);GLint location=pglGetAttribLocation(program,"position");if(location<0)goto done;
    GLenum shader_error=pglGetError();printf("GL_ERROR after shaders=0x%x\n",shader_error);
    GLint color=pglGetUniformLocation(program,"color");if(color<0)goto done;
    const GLfloat vertices[]={-1,-1,-0.5f,1,-1,-0.5f,0,1,-0.5f,-1,-1,0.5f,1,-1,0.5f,0,1,0.5f};GLuint vbo;pglGenBuffers(1,&vbo);pglBindBuffer(0x8892,vbo);pglBufferData(0x8892,sizeof(vertices),vertices,0x88e4);
    pglEnableVertexAttribArray(location);pglVertexAttribPointer(location,3,GL_FLOAT,GL_FALSE,0,NULL);
    GLenum buffer_error=pglGetError();printf("GL_ERROR after VBO=0x%x\n",buffer_error);
    EXTPROC(glGenFramebuffers,void,GLsizei,GLuint *);
    EXTPROC(glBindFramebuffer,void,GLenum,GLuint);
    EXTPROC(glGenRenderbuffers,void,GLsizei,GLuint *);
    EXTPROC(glBindRenderbuffer,void,GLenum,GLuint);
    EXTPROC(glRenderbufferStorageMultisample,void,GLenum,GLsizei,GLenum,GLsizei,GLsizei);
    EXTPROC(glFramebufferRenderbuffer,void,GLenum,GLenum,GLenum,GLuint);
    EXTPROC(glCheckFramebufferStatus,GLenum,GLenum);
    EXTPROC(glBlitFramebuffer,void,GLint,GLint,GLint,GLint,GLint,GLint,GLint,GLint,GLbitfield,GLenum);
    if(msaa){
    if(!pglGenFramebuffers||!pglBindFramebuffer||!pglGenRenderbuffers||!pglBindRenderbuffer||!pglRenderbufferStorageMultisample||!pglFramebufferRenderbuffer||!pglCheckFramebufferStatus||!pglBlitFramebuffer)goto done;
    GLuint fbo,rb[2];pglGenFramebuffers(1,&fbo);pglBindFramebuffer(0x8d40,fbo);pglGenRenderbuffers(2,rb);
    pglBindRenderbuffer(0x8d41,rb[0]);pglRenderbufferStorageMultisample(0x8d41,4,0x8058,128,128);pglFramebufferRenderbuffer(0x8d40,0x8ce0,0x8d41,rb[0]);
    pglBindRenderbuffer(0x8d41,rb[1]);pglRenderbufferStorageMultisample(0x8d41,4,0x88f0,128,128);pglFramebufferRenderbuffer(0x8d40,0x821a,0x8d41,rb[1]);
    GLenum fbo_status=pglCheckFramebufferStatus(0x8d40);printf("MSAA framebuffer=0x%x; GL_ERROR=0x%x\n",fbo_status,pglGetError());if(fbo_status!=0x8cd5)goto done;
    }
    pglViewport(0,0,128,128);pglEnable(GL_DEPTH_TEST);pglClearColor(1,0,0,1);pglClear(GL_COLOR_BUFFER_BIT|GL_DEPTH_BUFFER_BIT);
    pglUniform4f(color,0,1,0,1);pglDrawArrays(GL_TRIANGLES,0,3);
    pglUniform4f(color,0,0,1,1);pglDrawArrays(GL_TRIANGLES,3,3);pglFinish();
    GLenum draw_error=pglGetError();printf("GL_ERROR after draw=0x%x\n",draw_error);
    if(msaa){
    pglBindFramebuffer(0x8ca9,0);pglBlitFramebuffer(0,0,128,128,0,0,128,128,GL_COLOR_BUFFER_BIT,GL_NEAREST);pglBindFramebuffer(0x8d40,0);pglFinish();
    GLenum resolve_error=pglGetError();printf("MSAA resolve GL_ERROR=0x%x\n",resolve_error);if(resolve_error)goto done;
    }
    GLubyte center[4]={0},corner[4]={0};pglReadPixels(64,64,1,1,GL_RGBA,GL_UNSIGNED_BYTE,center);pglReadPixels(1,126,1,1,GL_RGBA,GL_UNSIGNED_BYTE,corner);
    success=center[0]<8&&center[1]>247&&center[2]<8&&corner[0]>247&&corner[1]<8&&corner[2]<8;
    printf("Shader/depth triangles=%s; center=%u,%u,%u; background=%u,%u,%u\n",success?"PASS":"FAIL",center[0],center[1],center[2],corner[0],corner[1],corner[2]);
    GLenum error=pglGetError();printf("GL_ERROR after readback=0x%x\n",error);if(error)success=0;
    if(success&&present){
        if(!swap||!swap(dc)){puts("SwapBuffers failed");success=0;goto done;}
        GdiFlush();
        COLORREF pixel=GetPixel(dc,64,64),outside=GetPixel(dc,1,1),lower=GetPixel(dc,32,96);
        success=GetRValue(pixel)<8&&GetGValue(pixel)>247&&GetBValue(pixel)<8&&
                GetRValue(outside)>247&&GetGValue(outside)<8&&GetBValue(outside)<8&&
                GetRValue(lower)<8&&GetGValue(lower)>247&&GetBValue(lower)<8;
        printf("Window pixels=%s; center=0x%06lx; upper corner=0x%06lx; lower=0x%06lx\n",
               success?"PASS":"FAIL",pixel,outside,lower);
    }
    if(initial_error||shader_error||buffer_error||draw_error||!atlas_ok)success=0;
done:
    if(context){current(NULL,NULL);destroy(context);}
    if(dc)ReleaseDC(window,dc);if(window)DestroyWindow(window);UnregisterClassA(wc.lpszClassName,wc.hInstance);FreeLibrary(library);
    return success?0:1;
}
