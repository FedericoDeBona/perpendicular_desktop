// One authorized, pinned relay controller per VM for the current Mac session.
// App rebuilds and Windows restarts reuse this controller; no shell or arbitrary command.
#include <CommonCrypto/CommonDigest.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <libproc.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <limits.h>
static const char *pin="6546126c1759683fe85798da92409215d53c50e0f2b346b4f74a61babc8dbec2";
static volatile sig_atomic_t quitting;
static void finish(int value){(void)value;quitting=1;}
static int verify(const char *path) {
    int fd=open(path,O_RDONLY|O_NOFOLLOW);if(fd<0)return 0;
    CC_SHA256_CTX ctx;CC_SHA256_Init(&ctx);unsigned char b[16384],out[32];ssize_t n;
    while((n=read(fd,b,sizeof(b)))>0)CC_SHA256_Update(&ctx,b,(CC_LONG)n);
    close(fd);if(n<0)return 0;CC_SHA256_Final(out,&ctx);
    char hex[65];for(int i=0;i<32;i++)sprintf(hex+2*i,"%02x",out[i]);
    return strcmp(hex,pin)==0;
}
static int regular(const char *path,uid_t owner){
    struct stat st;return !lstat(path,&st)&&S_ISREG(st.st_mode)&&st.st_uid==owner&&!(st.st_mode&077);
}
static int process_matches(pid_t pid,const char *path){
    char executable[PROC_PIDPATHINFO_MAXSIZE];struct proc_bsdinfo info;
    return proc_pidpath(pid,executable,sizeof(executable))>0&&!strcmp(executable,path)&&
        proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))==sizeof(info)&&info.pbi_uid==0;
}
// Migration is limited to the legacy root pair at these exact per-VM paths.
// The new controller lock is already held. Never terminate unrelated processes.
static int retire_legacy(const char *binary,const char *supervisor){
    int bytes=proc_listpids(PROC_ALL_PIDS,0,NULL,0);if(bytes<=0)return 0;
    pid_t *pids=calloc(1,(size_t)bytes+4096);if(!pids)return 0;
    int count=proc_listpids(PROC_ALL_PIDS,0,pids,bytes+4096)/(int)sizeof(pid_t);
    for(int i=0;i<count;i++){
        pid_t child=pids[i];if(child<=0||child==getpid()||!process_matches(child,binary))continue;
        struct proc_bsdinfo info;
        if(proc_pidinfo(child,PROC_PIDTBSDINFO,0,&info,sizeof(info))!=sizeof(info)||
           info.pbi_ppid==(uint32_t)getpid()||!process_matches((pid_t)info.pbi_ppid,supervisor)){free(pids);return 0;}
        pid_t parent=(pid_t)info.pbi_ppid;
        if(kill(child,SIGTERM)&&errno!=ESRCH){free(pids);return 0;}
        for(int n=0;n<100&&process_matches(child,binary);n++)usleep(100000);
        if(process_matches(child,binary)){free(pids);return 0;}
        if(process_matches(parent,supervisor))kill(parent,SIGTERM);
        for(int n=0;n<50&&process_matches(parent,supervisor);n++)usleep(100000);
        if(process_matches(parent,supervisor)){free(pids);return 0;}
    }
    free(pids);return 1;
}
static int listener(const char *path,uid_t owner,gid_t group,int retire){
    struct stat st;
    if(lstat(path,&st)==0){
        if(!retire||!S_ISSOCK(st.st_mode)||(st.st_uid!=owner&&st.st_uid!=0)||(st.st_mode&0777)!=0600)return -1;
        if(unlink(path))return -1;
    }else if(errno!=ENOENT)return -1;
    int fd=socket(AF_UNIX,SOCK_STREAM,0);if(fd<0)return -1;
    struct sockaddr_un addr={0};addr.sun_family=AF_UNIX;strcpy(addr.sun_path,path);
    if(bind(fd,(struct sockaddr*)&addr,sizeof(addr))||chmod(path,0600)||chown(path,owner,group)||listen(fd,8)){
        close(fd);return -1;
    }
    return fd;
}
static pid_t start_child(const char *binary,const char *config,uid_t owner,int control,int lock,int output){
    if(!verify(binary)||!regular(config,owner))return -1;
    pid_t pid=fork();
    if(pid==0){close(control);close(lock);dup2(output,1);dup2(output,2);close(output);execl(binary,binary,"run","-c",config,NULL);_exit(127);}
    return pid;
}
int main(int argc,char **argv){
    if(geteuid()!=0||argc!=2)return 2;
    // Authorization Services may leave a standard descriptor closed. Reserve all
    // three before opening control/lock descriptors, then daemonize safely.
    for(int i=0;i<3;i++)if(fcntl(i,F_GETFD)<0){int fd=open("/dev/null",O_RDWR);if(fd<0)return 2;if(fd!=i){dup2(fd,i);close(fd);}}
    signal(SIGPIPE,SIG_IGN);signal(SIGTERM,finish);signal(SIGINT,finish);
    char root[PATH_MAX],binary[PATH_MAX],config[PATH_MAX],log[PATH_MAX],sock[PATH_MAX],lockpath[PATH_MAX],self[PATH_MAX];
    if(!realpath(argv[1],root))return 2;
    struct stat st;if(lstat(root,&st)||!S_ISDIR(st.st_mode)||st.st_uid==0||(st.st_mode&077)!=0)return 2;
    uid_t owner=st.st_uid;gid_t group=st.st_gid;
    if(strlen(root)>PATH_MAX-32)return 2;
    snprintf(binary,sizeof(binary),"%s/sing-box",root);snprintf(config,sizeof(config),"%s/client-tun.json",root);
    snprintf(log,sizeof(log),"%s/tun.log",root);snprintf(sock,sizeof(sock),"%s/tun.sock",root);
    snprintf(lockpath,sizeof(lockpath),"%s/supervisor.lock",root);snprintf(self,sizeof(self),"%s/supervisor",root);
    if(strlen(sock)>=sizeof(((struct sockaddr_un*)0)->sun_path)||!verify(binary)||!regular(config,owner))return 2;
    int lock=open(lockpath,O_RDWR|O_CREAT|O_NOFOLLOW,0600);if(lock<0)return 2;
    if(fstat(lock,&st)||!S_ISREG(st.st_mode)||(st.st_uid!=0&&st.st_uid!=owner)||(st.st_mode&077)!=0){close(lock);return 2;}
    if(flock(lock,LOCK_EX|LOCK_NB)){close(lock);fprintf(stderr,"Controller already running; retained\n");return 1;}
    if(!retire_legacy(binary,self)){close(lock);fprintf(stderr,"Existing relay could not be stopped safely\n");return 2;}
    int control=listener(sock,owner,group,1);if(control<0){perror("control");close(lock);return 2;}
    pid_t supervisor=fork();if(supervisor<0){close(control);unlink(sock);close(lock);return 2;}
    if(supervisor>0){printf("Supervisor started: %d\n",supervisor);fflush(stdout);close(control);close(lock);return 0;}
    setsid();int null=open("/dev/null",O_RDWR);dup2(null,0);dup2(null,1);dup2(null,2);if(null>2)close(null);
    int output=open(log,O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW,0600);
    if(output<0){close(control);unlink(sock);close(lock);return 2;}fchown(output,owner,group);
    pid_t child=start_child(binary,config,owner,control,lock,output);
    while(!quitting){
        if(child>0){int status;pid_t done=waitpid(child,&status,WNOHANG);if(done==child||(done<0&&errno==ECHILD))child=0;}
        // Repair an unlinked control name without replacing another socket.
        if(lstat(sock,&st)&&errno==ENOENT){int next=listener(sock,owner,group,0);if(next>=0){close(control);control=next;}}
        struct pollfd p={control,POLLIN,0};if(poll(&p,1,500)<=0)continue;
        int client=accept(control,NULL,NULL);if(client<0)continue;
        uid_t uid;gid_t gid;
        if(getpeereid(client,&uid,&gid)==0&&(uid==owner||uid==0)){
            struct pollfd c={client,POLLIN,0};char command[16]={0};
            if(poll(&c,1,1000)>0&&read(client,command,15)>0){
                const char *reply="invalid\n";
                if(!strcmp(command,"status\n"))reply=child>0?"running\n":"stopped\n";
                else if(!strcmp(command,"start\n")){
                    if(child<=0)child=start_child(binary,config,owner,control,lock,output);
                    reply=child>0?"running\n":"stopped\n";
                }else if(!strcmp(command,"stop\n")){if(child>0)kill(child,SIGTERM);reply="stopping\n";}
                else if(!strcmp(command,"reload\n")){if(child>0)kill(child,SIGHUP);reply=child>0?"reloading\n":"stopped\n";}
                write(client,reply,strlen(reply));
            }
        }
        close(client);
    }
    if(child>0){kill(child,SIGTERM);for(int i=0;i<50;i++){if(waitpid(child,NULL,WNOHANG)!=0)break;usleep(100000);}}
    close(output);close(control);unlink(sock);close(lock);return 0;
}
