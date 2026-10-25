/* ARM64, no CRT. Runs only in an authenticated app's window thread.
 * Mouse messages are dispatched inside that window's child tree: the hidden
 * HWND is never made visible and global WindowFromPoint is never bypassed.
 */
typedef void *HANDLE;
typedef HANDLE HWND;
typedef unsigned int UINT;
typedef unsigned long DWORD;
typedef unsigned long long UPTR;
typedef long long IPTR;
typedef unsigned short WCHAR;
typedef struct { long x, y; } POINT;
typedef struct { long left, top, right, bottom; } RECT;
typedef struct { IPTR lParam; UPTR wParam; UINT message; HWND hwnd; } CWPSTRUCT;
typedef struct { HWND hwnd; UINT message; UPTR wParam; IPTR lParam; DWORD time; POINT pt; DWORD private_data; } MSG;
#define API __declspec(dllimport)
API DWORD __stdcall GetWindowThreadProcessId(HWND,DWORD*);
API DWORD __stdcall GetCurrentProcessId(void);
API UINT __stdcall RegisterWindowMessageW(const WCHAR*);
API HANDLE __stdcall GetPropW(HWND,const WCHAR*);
API int __stdcall SetPropW(HWND,const WCHAR*,HANDLE);
API HANDLE __stdcall RemovePropW(HWND,const WCHAR*);
API IPTR __stdcall CallNextHookEx(HANDLE,int,UPTR,IPTR);
API long __stdcall DwmSetWindowAttribute(HWND,DWORD,const void*,DWORD);
API int __stdcall IsWindow(HWND);
API int __stdcall IsWindowEnabled(HWND);
API int __stdcall GetClientRect(HWND,RECT*);
API int __stdcall ScreenToClient(HWND,POINT*);
API int __stdcall SetCursorPos(int,int);
API int __stdcall SetForegroundWindow(HWND);
API HWND __stdcall GetFocus(void);
API HWND __stdcall SetFocus(HWND);
API HWND __stdcall ChildWindowFromPointEx(HWND,POINT,UINT);
API HWND __stdcall GetAncestor(HWND,UINT);
API HWND __stdcall GetCapture(void);
API int __stdcall ReleaseCapture(void);
API int __stdcall GetKeyboardState(unsigned char*);
API int __stdcall SetKeyboardState(const unsigned char*);
API IPTR __stdcall SendMessageW(HWND,UINT,UPTR,IPTR);
API int __stdcall PostMessageW(HWND,UINT,UPTR,IPTR);
API HANDLE __stdcall OpenProcess(DWORD,int,DWORD);
API DWORD __stdcall WaitForSingleObject(HANDLE,DWORD);
API int __stdcall CloseHandle(HANDLE);
API int __stdcall GetModuleHandleExW(DWORD,const WCHAR*,HANDLE*);
API int __stdcall FreeLibrary(HANDLE);
API HANDLE __stdcall CreateThread(void*,UPTR,DWORD(__stdcall*)(void*),void*,DWORD,DWORD*);
API void __stdcall FreeLibraryAndExitThread(HANDLE,DWORD);
API HANDLE __stdcall GetProcessHeap(void);
API void* __stdcall HeapAlloc(HANDLE,DWORD,UPTR);
API int __stdcall HeapFree(HANDLE,DWORD,void*);
API DWORD __stdcall GetDoubleClickTime(void);
API UPTR __stdcall GetTickCount64(void);

static const WCHAR request[]=L"Perpendicular.Window.Request";
static const WCHAR owner[]=L"Perpendicular.Window.Controller";
static const WCHAR result[]=L"Perpendicular.Window.Result";
static const WCHAR recipient[]=L"Perpendicular.Window.Recipient";
static const WCHAR operation[]=L"Perpendicular.Window.Operation";
static const WCHAR buttons[]=L"Perpendicular.Window.Buttons";
static const WCHAR delta[]=L"Perpendicular.Window.Delta";
static const WCHAR last_click[]=L"Perpendicular.Window.LastClick";
static const WCHAR last_point[]=L"Perpendicular.Window.LastPoint";
static const WCHAR last_child[]=L"Perpendicular.Window.LastChild";
static const WCHAR last_button[]=L"Perpendicular.Window.LastButton";

typedef struct { HWND root; DWORD controller; HANDLE process,module; } WATCH;
static DWORD __stdcall recover(void *arg) {
 WATCH *watch=(WATCH*)arg;
 HWND h=watch->root;DWORD controller=watch->controller;
 HANDLE process=watch->process,module=watch->module;
 HeapFree(GetProcessHeap(),0,watch);
 while(process && IsWindow(h) && (DWORD)(UPTR)GetPropW(h,owner)==controller) {
  if(WaitForSingleObject(process,250)==0 || GetTickCount64()-(UPTR)GetPropW(h,L"Perpendicular.Window.Beat")>3000) {
   int no=0;DwmSetWindowAttribute(h,13,&no,4);
   PostMessageW(h,0x001f,0,0); /* WM_CANCELMODE */
   RemovePropW(h,owner);break;
  }
 }
 if((DWORD)(UPTR)GetPropW(h,L"Perpendicular.Window.Watch")==controller)
  RemovePropW(h,L"Perpendicular.Window.Watch");
 if(process)CloseHandle(process);
 FreeLibraryAndExitThread(module,0);return 0;
}

/* Result codes are positive protocol errors, not HRESULT success aliases. */
static DWORD dispatch(HWND root,UINT op,long sx,long sy) {
 if(op==10) {SetForegroundWindow(root);return 0;}
 if(op==1 || op==2) {
  int cloak=op==1;
  if(cloak && !GetPropW(root,owner))return 1;
  long hr=DwmSetWindowAttribute(root,13,&cloak,4);
  if(hr<0)return (DWORD)hr;
  DWORD controller=(DWORD)(UPTR)GetPropW(root,owner);
  if(cloak && (DWORD)(UPTR)GetPropW(root,L"Perpendicular.Window.Watch")!=controller) {
   WATCH *watch=(WATCH*)HeapAlloc(GetProcessHeap(),8,sizeof(WATCH));
   if(!watch){cloak=0;DwmSetWindowAttribute(root,13,&cloak,4);return 2;}
   watch->root=root;watch->controller=controller;
   watch->process=OpenProcess(0x00100000,0,controller);
   GetModuleHandleExW(4,(const WCHAR*)&recover,&watch->module);
   HANDLE thread=(watch->process && watch->module)?CreateThread(0,0,recover,watch,0,0):0;
   if(!thread){
    if(watch->process)CloseHandle(watch->process);if(watch->module)FreeLibrary(watch->module);
    HeapFree(GetProcessHeap(),0,watch);cloak=0;DwmSetWindowAttribute(root,13,&cloak,4);return 2;
   }
   CloseHandle(thread);SetPropW(root,L"Perpendicular.Window.Watch",(HANDLE)(UPTR)controller);
  }
  if(!cloak)RemovePropW(root,owner);
  return 0;
 }
 if(op==9) {
  SendMessageW(root,0x001f,0,0);
  HWND capture=GetCapture();
  if(capture && GetAncestor(capture,2)==root) {
   SendMessageW(capture,0x001f,0,0);ReleaseCapture();
  }
  return 0;
 }
 if(op<3 || op>8 || !IsWindowEnabled(root))return 3;
 if(op==4 || op==6)SetForegroundWindow(root);
 SetCursorPos(sx,sy);
 UINT native_hit=(UINT)SendMessageW(root,0x0084,0,(unsigned short)sx|((UPTR)(unsigned short)sy<<16));
 if(native_hit==8||native_hit==9||native_hit==20) {
  if(op==4)SetPropW(root,L"Perpendicular.Window.NCButton",(HANDLE)(UPTR)native_hit);
  if(op==5) {
   UINT pressed=(UINT)(UPTR)RemovePropW(root,L"Perpendicular.Window.NCButton");
   if(pressed==native_hit) {
    UINT command=native_hit==20?0xf060:native_hit==8?0xf020:0xf030;
    return PostMessageW(root,native_hit==20?0x0010:0x0112,native_hit==20?0:command,0)?0:13;
   }
  }
  return 0;
 }
 if(native_hit>1 && native_hit<=21 && op!=8) {
  UINT nc=op==3?0x00a0:op==4?0x00a1:op==5?0x00a2:op==6?0x00a4:0x00a5;
  return PostMessageW(root,nc,native_hit,(unsigned short)sx|((UPTR)(unsigned short)sy<<16))?0:13;
 }
 POINT p={sx,sy};HWND target=GetCapture();
 if(target && GetAncestor(target,2)!=root)return 4;
 if(!target) {
  target=root;
  for(int depth=0;depth<32;depth++) {
   POINT local=p;RECT rect;
   if(!ScreenToClient(target,&local)||!GetClientRect(target,&rect))return 5;
   if(local.x<0||local.y<0||local.x>=rect.right||local.y>=rect.bottom)return 6;
   HWND child=ChildWindowFromPointEx(target,local,7);
   if(!child || child==target)break;
   DWORD child_pid=0;
   GetWindowThreadProcessId(child,&child_pid);
   if(child_pid!=GetCurrentProcessId())return 7;
   target=child;
  }
 }
 if(GetAncestor(target,2)!=root || !IsWindowEnabled(target))return 8;
 SetPropW(root,recipient,target);
 if(op==4 || op==6)SetFocus(target);
 POINT local=p;if(!ScreenToClient(target,&local))return 9;
 if(local.x < -32768 || local.x>32767 || local.y < -32768 || local.y>32767)return 10;
 UINT msg=op==3?0x0200:op==4?0x0201:op==5?0x0202:op==6?0x0204:op==7?0x0205:0x020a;
 unsigned int state=(unsigned int)(UPTR)GetPropW(root,buttons);
 unsigned char keys[256];
 if(!GetKeyboardState(keys))return 11;
 UPTR wp=(state&1?1:0)|(state&2?2:0)|(keys[0x10]&128?4:0)|(keys[0x11]&128?8:0);
 IPTR lp=(unsigned short)local.x|((UPTR)(unsigned short)local.y<<16);
 if(op==4 || op==6) {
  UINT hit=(UINT)SendMessageW(target,0x0084,0,(unsigned short)sx|((UPTR)(unsigned short)sy<<16));
  IPTR activation=SendMessageW(target,0x0021,(UPTR)root,(hit&0xffff)|((UPTR)msg<<16));
  if(activation==2||activation==4)return 0;
  UPTR now=GetTickCount64(),old=(UPTR)GetPropW(root,last_click);
  UPTR pt=(unsigned short)local.x|((UPTR)(unsigned short)local.y<<16);
  if(old && now-old<=GetDoubleClickTime() && GetPropW(root,last_child)==target &&
     (UPTR)GetPropW(root,last_point)==pt && (UPTR)GetPropW(root,last_button)==op) {
   msg=op==4?0x0203:0x0206;RemovePropW(root,last_click);
  } else {
   SetPropW(root,last_click,(HANDLE)now);SetPropW(root,last_point,(HANDLE)pt);SetPropW(root,last_child,target);
   SetPropW(root,last_button,(HANDLE)(UPTR)op);
  }
 }
 if(op==8) {
  wp|=((UPTR)(unsigned short)(UPTR)GetPropW(root,delta))<<16;
  lp=(unsigned short)sx|((UPTR)(unsigned short)sy<<16);
 }
 return PostMessageW(target,msg,wp,lp)?0:14;
}

/* Post mouse input so a button/menu can enter its modal loop without
 * blocking the broker. Supply the corresponding per-thread button state
 * when the app actually removes that message from its queue. */
__declspec(dllexport) IPTR __stdcall PerpendicularMessageHook(int code,UPTR w,IPTR l) {
 if(code>=0 && w==1 && l) {
  MSG *m=(MSG*)l;HWND root=GetAncestor(m->hwnd,2);
  if(GetPropW(root,owner) && m->message>=0x0200 && m->message<=0x020e) {
   unsigned char keys[256];
   if(GetKeyboardState(keys)) {
    keys[1]=(m->wParam&1)?128:0;keys[2]=(m->wParam&2)?128:0;
    SetKeyboardState(keys);
   }
  }
 }
 return CallNextHookEx(0,code,w,l);
}

__declspec(dllexport) IPTR __stdcall PerpendicularWindowHook(int code,UPTR w,IPTR l) {
 if(code>=0 && l) {
  const CWPSTRUCT *m=(const CWPSTRUCT*)l;DWORD pid=0;
  if(m->message==RegisterWindowMessageW(L"Perpendicular.Window.83cf5732-02d7-48a2-b121-ef5973d04b95") &&
     m->wParam && GetPropW(m->hwnd,request)==(HANDLE)m->wParam &&
     GetWindowThreadProcessId(m->hwnd,&pid) && pid==GetCurrentProcessId()) {
   UINT op=(UINT)(UPTR)GetPropW(m->hwnd,operation);
   DWORD answer=dispatch(m->hwnd,op,(long)m->lParam,(long)((UPTR)m->lParam>>32));
   SetPropW(m->hwnd,result,(HANDLE)((UPTR)answer+1));
  }
 }
 return CallNextHookEx(0,code,w,l);
}
