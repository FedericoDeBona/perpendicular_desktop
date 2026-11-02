// Narrow real-Metal video-processor check: truthful caps, pixel conversion,
// crop/scale/target preservation, resource lifetime, and unsupported state.
#include <d3d11_4.h>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <vector>
#include <algorithm>
static void check(HRESULT hr,const char *name){if(FAILED(hr)){std::fprintf(stderr,"%s: %08x\n",name,unsigned(hr));std::exit(2);}}
static void expect(bool pass,const char *name){if(!pass){std::fprintf(stderr,"FAIL %s\n",name);std::exit(3);}}
static int channelByte(float v){return int(std::lround(std::clamp(v,0.f,1.f)*255));}
int main(){
 ID3D11Device *dev=nullptr;ID3D11DeviceContext *ctx=nullptr;D3D_FEATURE_LEVEL fl=D3D_FEATURE_LEVEL_11_0;
 UINT deviceFlags=0;
#if defined(_WIN32) && !defined(__APPLE__)
 deviceFlags=D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
#endif
 check(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,deviceFlags,&fl,1,D3D11_SDK_VERSION,&dev,nullptr,&ctx),"device");
 ID3D11VideoDevice *video=nullptr;ID3D11VideoContext *vc=nullptr;
 check(dev->QueryInterface(__uuidof(ID3D11VideoDevice),(void**)&video),"VideoDevice");check(ctx->QueryInterface(__uuidof(ID3D11VideoContext),(void**)&vc),"VideoContext");
 D3D11_VIDEO_PROCESSOR_CONTENT_DESC content={};content.InputFrameFormat=D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
 content.InputWidth=8;content.InputHeight=4;content.OutputWidth=16;content.OutputHeight=8;content.InputFrameRate={60,1};content.OutputFrameRate={60,1};
 ID3D11VideoProcessorEnumerator *enumerator=nullptr;check(video->CreateVideoProcessorEnumerator(&content,&enumerator),"processor enumeration");
 UINT formats=0,support=0;check(enumerator->CheckVideoProcessorFormat(DXGI_FORMAT_NV12,&formats),"NV12 caps");expect(formats==D3D11_VIDEO_PROCESSOR_FORMAT_SUPPORT_INPUT,"NV12 input only");
 check(dev->CheckFormatSupport(DXGI_FORMAT_NV12,&support),"NV12 device format");std::printf("NV12 device support mask=%08x\n",support);expect(support&D3D11_FORMAT_SUPPORT_VIDEO_PROCESSOR_INPUT,"NV12 device input");
#if !defined(_WIN32) || defined(__APPLE__)
 // Windows FL11.0 supplies mandatory generic NV12 format bits; the specific
 // processor enumerator above is the actual input/output capability gate.
 expect(!(support&D3D11_FORMAT_SUPPORT_VIDEO_PROCESSOR_OUTPUT),"native NV12 device input only");
#endif
 check(dev->CheckFormatSupport(DXGI_FORMAT_B8G8R8A8_UNORM,&support),"BGRA device format");expect(support&D3D11_FORMAT_SUPPORT_VIDEO_PROCESSOR_OUTPUT,"BGRA device output");
 check(enumerator->CheckVideoProcessorFormat(DXGI_FORMAT_P010,&formats),"P010 caps");expect(!formats,"P010 unsupported");
 D3D11_VIDEO_PROCESSOR_CAPS caps={};check(enumerator->GetVideoProcessorCaps(&caps),"caps");expect(caps.MaxInputStreams==1&&caps.RateConversionCapsCount==1&&!caps.FilterCaps&&!caps.StereoCaps,"narrow caps");
 auto interlaced=content;interlaced.InputFrameFormat=D3D11_VIDEO_FRAME_FORMAT_INTERLACED_TOP_FIELD_FIRST;ID3D11VideoProcessorEnumerator *bad=nullptr;
 expect(FAILED(video->CreateVideoProcessorEnumerator(&interlaced,&bad))&&!bad,"interlace rejected");
 ID3D11VideoProcessor *processor=nullptr;check(video->CreateVideoProcessor(enumerator,0,&processor),"processor");
 D3D11_TEXTURE2D_DESC td={};td.Width=8;td.Height=4;td.MipLevels=td.ArraySize=td.SampleDesc.Count=1;td.Format=DXGI_FORMAT_NV12;td.Usage=D3D11_USAGE_DEFAULT;td.BindFlags=D3D11_BIND_DECODER|D3D11_BIND_SHADER_RESOURCE;
 ID3D11Texture2D *nv12=nullptr;check(dev->CreateTexture2D(&td,nullptr,&nv12),"NV12");
 D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC inDesc={};inDesc.ViewDimension=D3D11_VPIV_DIMENSION_TEXTURE2D;
 ID3D11VideoProcessorInputView *input=nullptr;check(video->CreateVideoProcessorInputView(nv12,enumerator,&inDesc,&input),"input view");
 td.Width=16;td.Height=8;td.Format=DXGI_FORMAT_B8G8R8A8_UNORM;td.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE;
 ID3D11Texture2D *output=nullptr,*staging=nullptr;check(dev->CreateTexture2D(&td,nullptr,&output),"output");
 td.BindFlags=0;td.Usage=D3D11_USAGE_STAGING;td.CPUAccessFlags=D3D11_CPU_ACCESS_READ;check(dev->CreateTexture2D(&td,nullptr,&staging),"staging");
 D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC outDesc={};outDesc.ViewDimension=D3D11_VPOV_DIMENSION_TEXTURE2D;
 D3D11_TEXTURE2D_DESC rejectedDesc=td;rejectedDesc.Width=8;rejectedDesc.Height=4;rejectedDesc.Format=DXGI_FORMAT_NV12;rejectedDesc.BindFlags=D3D11_BIND_RENDER_TARGET;rejectedDesc.Usage=D3D11_USAGE_DEFAULT;rejectedDesc.CPUAccessFlags=0;
 ID3D11Texture2D *rejectedTarget=nullptr;check(dev->CreateTexture2D(&rejectedDesc,nullptr,&rejectedTarget),"NV12 unsupported-output resource");
 ID3D11VideoProcessorOutputView *rejectedView=nullptr;expect(FAILED(video->CreateVideoProcessorOutputView(rejectedTarget,enumerator,&outDesc,&rejectedView))&&!rejectedView,"NV12 processor output rejected");rejectedTarget->Release();
 ID3D11VideoProcessorOutputView *outView=nullptr;check(video->CreateVideoProcessorOutputView(output,enumerator,&outDesc,&outView),"output view");
 std::vector<unsigned char> init(16*8*4,37),pixels(8*4*3/2);D3D11_VIDEO_PROCESSOR_STREAM stream={};stream.Enable=TRUE;stream.pInputSurface=input;
 RECT src={0,0,8,4},dst={4,2,12,6},target={2,1,14,7};vc->VideoProcessorSetStreamSourceRect(processor,0,TRUE,&src);vc->VideoProcessorSetStreamDestRect(processor,0,TRUE,&dst);vc->VideoProcessorSetOutputTargetRect(processor,TRUE,&target);
 D3D11_VIDEO_COLOR bg={};bg.RGBA.R=.1;bg.RGBA.G=.2;bg.RGBA.B=.3;bg.RGBA.A=1;vc->VideoProcessorSetOutputBackgroundColor(processor,FALSE,&bg);
 BOOL automatic=FALSE;vc->VideoProcessorGetStreamAutoProcessingMode(processor,0,&automatic);expect(automatic,"automatic processing default enabled");
 // No automatic enhancement caps: both states must retain the same conversion.
 vc->VideoProcessorSetStreamAutoProcessingMode(processor,0,FALSE);vc->VideoProcessorGetStreamAutoProcessingMode(processor,0,&automatic);expect(!automatic,"automatic processing disabled state");vc->VideoProcessorSetStreamAutoProcessingMode(processor,0,TRUE);
 bool outputRgba=false;
 auto readCheck=[&](int red,int green,int blue,const char *label){ctx->CopyResource(staging,output);D3D11_MAPPED_SUBRESOURCE map={};check(ctx->Map(staging,0,D3D11_MAP_READ,0,&map),"read");
  for(unsigned y=0;y<8;y++)for(unsigned x=0;x<16;x++){auto p=(const unsigned char*)map.pData+y*map.RowPitch+x*4;
   bool inner=x>=4&&x<12&&y>=2&&y<6,inside=x>=2&&x<14&&y>=1&&y<7;int e[4]={37,37,37,37};if(inside){e[0]=channelByte(.3);e[1]=channelByte(.2);e[2]=channelByte(.1);e[3]=255;}if(inner){e[0]=blue;e[1]=green;e[2]=red;e[3]=255;}
   if(outputRgba)std::swap(e[0],e[2]);
   for(unsigned c=0;c<4;c++)if(std::abs(int(p[c])-e[c])>2){std::fprintf(stderr,"%s pixel%u,%u channel%u got%u want%d\n",label,x,y,c,p[c],e[c]);std::exit(3);}}
  ctx->Unmap(staging,0);std::printf("%s PASS\n",label);
 };
 for(unsigned pass=0;pass<3;pass++){
  bool full=pass==2,matrix=pass!=0;std::fill(pixels.begin(),pixels.begin()+32,81);for(unsigned i=32;i<48;i+=2){pixels[i]=90;pixels[i+1]=240;}
  ctx->UpdateSubresource(nv12,0,nullptr,pixels.data(),8,0);ctx->UpdateSubresource(output,0,nullptr,init.data(),64,0);
  D3D11_VIDEO_PROCESSOR_COLOR_SPACE color={};color.YCbCr_Matrix=matrix;color.Nominal_Range=full?2:1;vc->VideoProcessorSetStreamColorSpace(processor,0,&color);
  check(vc->VideoProcessorBlt(processor,outView,0,1,&stream),"NV12 blit");
  float y=(81.f-(full?0:16))/(full?255:219),u=(90.f-128)/(full?255:224),v=(240.f-128)/(full?255:224);
  readCheck(channelByte(y+(matrix?1.5748f:1.402f)*v),channelByte(y-(matrix?.187324f:.344136f)*u-(matrix?.468124f:.714136f)*v),channelByte(y+(matrix?1.8556f:1.772f)*u),pass==0?"BT601 limited crop/scale":pass==1?"BT709 limited crop/scale":"BT709 full crop/scale");
 }
 vc->VideoProcessorSetOutputBackgroundColor(processor,TRUE,&bg);expect(FAILED(vc->VideoProcessorBlt(processor,outView,0,1,&stream)),"unsupported YUV background rejected");vc->VideoProcessorSetOutputBackgroundColor(processor,FALSE,&bg);
#if !defined(_WIN32) || defined(__APPLE__)
 vc->VideoProcessorSetOutputAlphaFillMode(processor,D3D11_VIDEO_PROCESSOR_ALPHA_FILL_MODE_DESTINATION,0);expect(FAILED(vc->VideoProcessorBlt(processor,outView,0,1,&stream)),"destination alpha rejected");vc->VideoProcessorSetOutputAlphaFillMode(processor,D3D11_VIDEO_PROCESSOR_ALPHA_FILL_MODE_OPAQUE,0);
 vc->VideoProcessorSetStreamFilter(processor,0,D3D11_VIDEO_PROCESSOR_FILTER_BRIGHTNESS,TRUE,1);expect(FAILED(vc->VideoProcessorBlt(processor,outView,0,1,&stream)),"unsupported filter rejected");vc->VideoProcessorSetStreamFilter(processor,0,D3D11_VIDEO_PROCESSOR_FILTER_BRIGHTNESS,FALSE,0);
#endif
 stream.PastFrames=1;expect(FAILED(vc->VideoProcessorBlt(processor,outView,0,1,&stream)),"past frame rejected");stream.PastFrames=0;
 // Crop the blue half of a BGRA source, then scale it into the destination.
 td={};td.Width=8;td.Height=4;td.MipLevels=td.ArraySize=td.SampleDesc.Count=1;td.Format=DXGI_FORMAT_B8G8R8A8_UNORM;td.Usage=D3D11_USAGE_DEFAULT;td.BindFlags=D3D11_BIND_SHADER_RESOURCE;
 std::vector<unsigned char> rgb(8*4*4,0);for(unsigned y=0;y<4;y++)for(unsigned x=0;x<8;x++){rgb[(y*8+x)*4+(x<4?2:0)]=255;rgb[(y*8+x)*4+3]=255;}
 D3D11_SUBRESOURCE_DATA data={rgb.data(),32,0};ID3D11Texture2D *bgra=nullptr;check(dev->CreateTexture2D(&td,&data,&bgra),"BGRA");ID3D11VideoProcessorInputView *bgraInput=nullptr;check(video->CreateVideoProcessorInputView(bgra,enumerator,&inDesc,&bgraInput),"BGRA input");
 stream.pInputSurface=bgraInput;src.left=4;vc->VideoProcessorSetStreamSourceRect(processor,0,TRUE,&src);D3D11_VIDEO_PROCESSOR_COLOR_SPACE rgbColor={};vc->VideoProcessorSetStreamColorSpace(processor,0,&rgbColor);ctx->UpdateSubresource(output,0,nullptr,init.data(),64,0);
 // Views retain resources independently of the caller's texture references.
 bgra->Release();check(vc->VideoProcessorBlt(processor,outView,0,1,&stream),"BGRA blit");readCheck(0,0,255,"BGRA crop and retained input");
 // The alternate RGB channel order has an independently compiled Metal pipeline.
 outView->Release();output->Release();staging->Release();outputRgba=true;
 td={};td.Width=16;td.Height=8;td.MipLevels=td.ArraySize=td.SampleDesc.Count=1;td.Format=DXGI_FORMAT_R8G8B8A8_UNORM;td.Usage=D3D11_USAGE_DEFAULT;td.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE;
 check(dev->CreateTexture2D(&td,nullptr,&output),"RGBA output");check(video->CreateVideoProcessorOutputView(output,enumerator,&outDesc,&outView),"RGBA view");
 td.BindFlags=0;td.Usage=D3D11_USAGE_STAGING;td.CPUAccessFlags=D3D11_CPU_ACCESS_READ;check(dev->CreateTexture2D(&td,nullptr,&staging),"RGBA staging");
 rgbColor.RGB_Range=1;vc->VideoProcessorSetOutputColorSpace(processor,&rgbColor);ctx->UpdateSubresource(output,0,nullptr,init.data(),64,0);
 check(vc->VideoProcessorBlt(processor,outView,0,1,&stream),"RGBA studio blit");readCheck(16,16,235,"RGBA output studio range");
 rgbColor.RGB_Range=0;vc->VideoProcessorSetOutputColorSpace(processor,&rgbColor);vc->VideoProcessorSetStreamAlpha(processor,0,TRUE,.5f);ctx->UpdateSubresource(output,0,nullptr,init.data(),64,0);
 check(vc->VideoProcessorBlt(processor,outView,0,1,&stream),"alpha blit");readCheck(channelByte(.05f),channelByte(.1f),channelByte(.65f),"stream alpha over background");
 vc->VideoProcessorSetStreamAlpha(processor,0,FALSE,1);
 bgraInput->Release();
 // RGBA input follows the same documented color order, not a hidden BGRA alias.
 for(size_t i=0;i<rgb.size();i+=4)std::swap(rgb[i],rgb[i+2]);td={};td.Width=8;td.Height=4;td.MipLevels=td.ArraySize=td.SampleDesc.Count=1;td.Format=DXGI_FORMAT_R8G8B8A8_UNORM;td.Usage=D3D11_USAGE_DEFAULT;td.BindFlags=D3D11_BIND_SHADER_RESOURCE;
 data={rgb.data(),32,0};check(dev->CreateTexture2D(&td,&data,&bgra),"RGBA input texture");check(video->CreateVideoProcessorInputView(bgra,enumerator,&inDesc,&bgraInput),"RGBA input view");bgra->Release();stream.pInputSurface=bgraInput;ctx->UpdateSubresource(output,0,nullptr,init.data(),64,0);
 check(vc->VideoProcessorBlt(processor,outView,0,1,&stream),"RGBA input blit");readCheck(0,0,255,"RGBA input channel order");
 bgraInput->Release();input->Release();nv12->Release();outView->Release();output->Release();staging->Release();processor->Release();enumerator->Release();vc->Release();video->Release();ctx->Release();dev->Release();
 std::puts("Progressive video processor capabilities, GPU pixels, crop/scale and unsupported cases PASS");return 0;
}
