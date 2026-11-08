#include <gum/guminterceptor.h>
#include <stdint.h>
#include <string.h>
extern uint64_t ticks(void);
extern unsigned char store[];
extern unsigned char counters[];
extern unsigned char limits[];
extern void get_srv(void *,uint32_t,uint32_t,void **);
extern void get_ps(void *,void **,void *,void *);
extern void get_vb(void *,uint32_t,uint32_t,void **,uint32_t *,uint32_t *);
extern void get_ib(void *,void **,uint32_t *,uint32_t *);
extern void get_rt(void *,uint32_t,void **,void *);
struct Stats {uint32_t total,records,errors,stopped,measured,filtered;uint64_t sum,max;};
struct Row {uint64_t tick,context,target,ps;uint32_t method,count,start;int32_t base;uint32_t width,height,stride,format,triangles,truncated;uint32_t srv[4][6];float bounds[64][4];};
static void release(void *o){if(o)((uint32_t(*)(void *))(*(void ***)o)[2])(o);}
static void desc(void *o,uint32_t *d){((void(*)(void *,void *))(*(void ***)o)[10])(o,d);}
static void *view_resource(void *v){void *r=0;if(v)((void(*)(void *,void **))(*(void ***)v)[7])(v,&r);return r;}
static uint32_t dimension(void *r){uint32_t d=0;((void(*)(void *,uint32_t *))(*(void ***)r)[7])(r,&d);return d;}
static const unsigned char *mapped(void *o,uint32_t *length){
 if(!o)return 0;uint32_t d[6]={0};desc(o,d);*length=d[0];
 unsigned char *b=*(unsigned char **)((unsigned char *)o+8);if(!b||*(uint64_t *)b!=d[0]||d[0]>16777216)return 0;
 unsigned char *a=*(unsigned char **)(b+8);uint32_t sub=0;unsigned char *dynamic=*(unsigned char **)((unsigned char *)o+136);
 if(dynamic&&*(void **)dynamic==b){a=*(unsigned char **)(dynamic+184);sub=*(uint32_t *)(dynamic+192);}else if(a)sub=*(uint32_t *)(a+704);
 if(!a)return 0;uint32_t stride=*(uint32_t *)(a+708),count=*(uint32_t *)(a+712);uint64_t capacity=*(uint64_t *)(a+624);unsigned char *p=*(unsigned char **)(a+688);
 if(!p||sub>=count||(uint64_t)sub*stride+d[0]>capacity)return 0;return p+(uint64_t)sub*stride;
}
static void capture(GumInvocationContext *ic,uint32_t method){
 struct Stats *s=(struct Stats *)counters;s->total++;if(s->stopped||s->records>=48)return;
 uint64_t began=ticks();void *ctx=gum_invocation_context_get_nth_argument(ic,0);void *rt=0,*resource=0,*ps=0,*views[4]={0},*vb[2]={0},*ib=0;
 uint32_t strides[2]={0},offsets[2]={0},format=0,iboffset=0,d[16]={0};
 struct Row row;memset(&row,0,sizeof(row));row.tick=began;row.context=(uintptr_t)ctx;row.method=method;
 get_rt(ctx,1,&rt,0);resource=view_resource(rt);if(!resource){s->filtered++;goto done;}if(dimension(resource)!=3){s->filtered++;goto done;}desc(resource,d);
 row.target=(uintptr_t)resource;row.width=d[0];row.height=d[1];
 /* Measured Settings surface in this QA baseline: no full-screen/taskbar capture. */
 if(d[0]!=955||d[1]!=614){s->filtered++;goto done;}
 get_ps(ctx,&ps,0,0);row.ps=(uintptr_t)ps;get_srv(ctx,0,4,views);get_vb(ctx,0,2,vb,strides,offsets);get_ib(ctx,&ib,&format,&iboffset);
 row.stride=strides[0];row.format=format;row.count=(uintptr_t)gum_invocation_context_get_nth_argument(ic,1);
 row.start=(uintptr_t)gum_invocation_context_get_nth_argument(ic,(method==3||method==4)?3:2);
 row.base=(method==1||method==3)?(int32_t)(uintptr_t)gum_invocation_context_get_nth_argument(ic,method==3?4:3):0;
 for(uint32_t i=0;i<4;i++){void *r=view_resource(views[i]);if(!r)continue;uint32_t dim=dimension(r),rd[16]={0},vd[16]={0};desc(r,rd);((void(*)(void *,void *))(*(void ***)views[i])[8])(views[i],vd);row.srv[i][0]=rd[0];row.srv[i][1]=dim==3?rd[1]:0;row.srv[i][2]=vd[0];row.srv[i][3]=dim;row.srv[i][4]=vd[2];row.srv[i][5]=vd[3];release(r);}
 uint32_t vlen=0,ilen=0;const unsigned char *vp=mapped(vb[0],&vlen),*ip=mapped(ib,&ilen);uint32_t sz=format==57?2:format==42?4:0;
 if(vp&&strides[0]>=8&&strides[0]<=128){uint32_t n=row.count/3;if(n>64){n=64;row.truncated=1;}
  for(uint32_t t=0;t<n;t++){float box[4]={1e30f,1e30f,-1e30f,-1e30f};uint32_t valid=1;
   for(uint32_t v=0;v<3;v++){uint32_t idx=row.start+t*3+v;if(method==1||method==3){uint64_t at=(uint64_t)iboffset+(uint64_t)idx*sz;if(!ip||!sz||at+sz>ilen){valid=0;break;}idx=sz==2?*(uint16_t *)(ip+at):*(uint32_t *)(ip+at);}
    int64_t at=(int64_t)offsets[0]+((int64_t)idx+row.base)*strides[0];if(at<0||(uint64_t)at+8>vlen){valid=0;break;}float x,y;memcpy(&x,vp+at,4);memcpy(&y,vp+at+4,4);if(x!=x||y!=y||x>100000||x< -100000||y>100000||y< -100000){valid=0;break;}if(x<box[0])box[0]=x;if(y<box[1])box[1]=y;if(x>box[2])box[2]=x;if(y>box[3])box[3]=y;}
   if(valid){memcpy(row.bounds[row.triangles],box,sizeof(box));row.triangles++;}}
 }
 memcpy(store+s->records*sizeof(row),&row,sizeof(row));s->records++;
 done:release(rt);release(resource);release(ps);release(ib);for(uint32_t i=0;i<4;i++)release(views[i]);for(uint32_t i=0;i<2;i++)release(vb[i]);
 uint64_t elapsed=ticks()-began;s->measured++;s->sum+=elapsed;if(elapsed>s->max)s->max=elapsed;if(elapsed>*(uint64_t *)limits)s->stopped=1;
}
void draw_indexed(GumInvocationContext *ic){capture(ic,1);}void draw(GumInvocationContext *ic){capture(ic,2);}void indexed_instanced(GumInvocationContext *ic){capture(ic,3);}void instanced(GumInvocationContext *ic){capture(ic,4);}
uint32_t row_size(void){return sizeof(struct Row);}
