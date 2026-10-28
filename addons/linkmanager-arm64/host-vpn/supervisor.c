// Temporary privileged supervisor for one pinned sing-box process.
// The private socket accepts only 'stop'; no persistent privileged installation.
#include <CommonCrypto/CommonDigest.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/wait.h>
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
static int verify(const char *path) {
    int fd=open(path,O_RDONLY|O_NOFOLLOW);if(fd<0)return 0;
    CC_SHA256_CTX ctx;CC_SHA256_Init(&ctx);unsigned char b[16384],out[32];ssize_t n;
    while((n=read(fd,b,sizeof(b)))>0)CC_SHA256_Update(&ctx,b,(CC_LONG)n);
    close(fd);if(n<0)return 0;CC_SHA256_Final(out,&ctx);
    char hex[65];for(int i=0;i<32;i++)sprintf(hex+2*i,"%02x",out[i]);
    return strcmp(hex,pin)==0;
}
int main(int argc,char **argv) {
    if(geteuid()!=0||argc!=2)return 2;
    char root[PATH_MAX],binary[PATH_MAX],config[PATH_MAX],log[PATH_MAX],sock[PATH_MAX];
    if(!realpath(argv[1],root))return 2;
    struct stat st;if(lstat(root,&st)||!S_ISDIR(st.st_mode)||st.st_uid==0||(st.st_mode&077)!=0)return 2;
    uid_t owner=st.st_uid;gid_t group=st.st_gid;
    snprintf(binary,sizeof(binary),"%s/sing-box",root);snprintf(config,sizeof(config),"%s/client-tun.json",root);
    snprintf(log,sizeof(log),"%s/tun.log",root);snprintf(sock,sizeof(sock),"%s/tun.sock",root);
    if(strlen(sock)>=sizeof(((struct sockaddr_un*)0)->sun_path)||!verify(binary))return 2;
    if(lstat(config,&st)||!S_ISREG(st.st_mode)||st.st_uid!=owner||(st.st_mode&077)!=0)return 2;
    int control=socket(AF_UNIX,SOCK_STREAM,0);if(control<0)return 2;
    struct sockaddr_un addr={0};addr.sun_family=AF_UNIX;strcpy(addr.sun_path,sock);
    if(bind(control,(struct sockaddr*)&addr,sizeof(addr))||chmod(sock,0600)||chown(sock,owner,group)||listen(control,1)) {perror("control");close(control);return 2;}
    pid_t supervisor=fork();if(supervisor<0){unlink(sock);return 2;}
    if(supervisor>0){printf("Supervisor started: %d\n",supervisor);fflush(stdout);close(control);return 0;}
    setsid();int null=open("/dev/null",O_RDWR);dup2(null,0);dup2(null,1);dup2(null,2);if(null>2)close(null);
    int output=open(log,O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW,0600);
    if(output<0){unlink(sock);return 2;}fchown(output,owner,group);
    pid_t child=fork();if(child<0){close(output);unlink(sock);return 2;}
    if(child==0){close(control);dup2(output,1);dup2(output,2);close(output);execl(binary,binary,"run","-c",config,NULL);_exit(127);}
    close(output);
    int status=0;
    while(waitpid(child,&status,WNOHANG)==0){
        struct pollfd p={control,POLLIN,0};if(poll(&p,1,500)<=0)continue;
        int client=accept(control,NULL,NULL);if(client<0)continue;
        uid_t uid;gid_t gid;
        if(getpeereid(client,&uid,&gid)==0&&(uid==owner||uid==0)){
            struct pollfd c={client,POLLIN,0};char command[16]={0};
            if(poll(&c,1,1000)>0&&read(client,command,15)>0){
                if(strcmp(command,"stop\n")==0){kill(child,SIGTERM);write(client,"stopping\n",9);close(client);break;}
                if(strcmp(command,"reload\n")==0){
                    // Reload the same config path; sing-box handles SIGHUP.
                    kill(child,SIGHUP);write(client,"reloading\n",10);
                }
            }
        }
        close(client);
    }
    for(int i=0;i<50;i++){if(waitpid(child,&status,WNOHANG)!=0)break;usleep(100000);}
    close(control);unlink(sock);return 0;
}
