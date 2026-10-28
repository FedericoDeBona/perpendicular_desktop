// Requests macOS authorization for the fixed companion supervisor. No shell.
#include <Security/Authorization.h>
#include <Security/AuthorizationTags.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(int argc,char **argv) {
    if(argc!=3) return 2;
    AuthorizationRef auth=NULL;
    const char *prompt="Perpendicular: attiva sul Mac gli indirizzi LinkManager selezionati.";
    AuthorizationItem item={kAuthorizationEnvironmentPrompt,0,(void*)prompt,0};
    item.valueLength=__builtin_strlen(prompt);
    AuthorizationEnvironment env={1,&item};
    OSStatus status=AuthorizationCreate(NULL,&env,kAuthorizationFlagDefaults,&auth);
    if(status) {fprintf(stderr,"AuthorizationCreate: %d\n",(int)status);return 1;}
    char *args[]={argv[2],NULL}; FILE *pipe=NULL;
    status=AuthorizationExecuteWithPrivileges(auth,argv[1],kAuthorizationFlagDefaults,args,&pipe);
    if(status) {fprintf(stderr,"Authorization: %d\n",(int)status);AuthorizationFree(auth,0);return 1;}
    char buffer[256]; if(pipe && fgets(buffer,sizeof(buffer),pipe))fputs(buffer,stdout);
    if(pipe)fclose(pipe);
    AuthorizationFree(auth,0);return 0;
}
