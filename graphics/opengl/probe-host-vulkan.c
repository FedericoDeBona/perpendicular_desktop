/* Run against an explicit private Vulkan library; never selects a CPU fallback. */
#include <vulkan/vulkan.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
    if (argc != 2) { fprintf(stderr, "Usage: %s /absolute/libMoltenVK.dylib\n", argv[0]); return 2; }
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    PFN_vkGetInstanceProcAddr get = (PFN_vkGetInstanceProcAddr)dlsym(library, "vkGetInstanceProcAddr");
    if (!get) { dlclose(library); return 1; }
    PFN_vkCreateInstance create = (PFN_vkCreateInstance)get(NULL, "vkCreateInstance");
    VkApplicationInfo app = { .sType=VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName="Perpendicular Vulkan prerequisite", .apiVersion=VK_API_VERSION_1_1 };
    const char *extension = "VK_KHR_portability_enumeration";
    PFN_vkEnumerateInstanceExtensionProperties instance_extensions = (PFN_vkEnumerateInstanceExtensionProperties)get(NULL,"vkEnumerateInstanceExtensionProperties");
    uint32_t instance_count=0; int portability=0;
    instance_extensions(NULL,&instance_count,NULL);
    VkExtensionProperties *instance_props=calloc(instance_count ? instance_count : 1,sizeof(*instance_props));
    if(instance_props && instance_extensions(NULL,&instance_count,instance_props)==VK_SUCCESS)
        for(uint32_t i=0;i<instance_count;i++) if(!strcmp(instance_props[i].extensionName,extension)) portability=1;
    free(instance_props);
    VkInstanceCreateInfo info = { .sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo=&app,
        .flags=portability ? VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR : 0,
        .enabledExtensionCount=portability ? 1 : 0, .ppEnabledExtensionNames=portability ? &extension : NULL };
    VkInstance instance = VK_NULL_HANDLE;
    VkResult result = create(&info, NULL, &instance);
    printf("create_instance=%d\n", result);
    if (result) { dlclose(library); return 1; }
    PFN_vkEnumeratePhysicalDevices enumerate = (PFN_vkEnumeratePhysicalDevices)get(instance,"vkEnumeratePhysicalDevices");
    PFN_vkGetPhysicalDeviceProperties properties = (PFN_vkGetPhysicalDeviceProperties)get(instance,"vkGetPhysicalDeviceProperties");
    PFN_vkEnumerateDeviceExtensionProperties extensions = (PFN_vkEnumerateDeviceExtensionProperties)get(instance,"vkEnumerateDeviceExtensionProperties");
    PFN_vkGetPhysicalDeviceFeatures2 features = (PFN_vkGetPhysicalDeviceFeatures2)get(instance,"vkGetPhysicalDeviceFeatures2");
    PFN_vkDestroyInstance destroy = (PFN_vkDestroyInstance)get(instance,"vkDestroyInstance");
    uint32_t count = 0;
    result = enumerate(instance, &count, NULL);
    printf("enumerate=%d; devices=%u\n", result, count);
    VkPhysicalDevice *devices = calloc(count ? count : 1, sizeof(*devices));
    int hardware = 0;
    if (result == VK_SUCCESS && count && devices && enumerate(instance,&count,devices)==VK_SUCCESS) {
        for (uint32_t i=0; i<count; ++i) {
            VkPhysicalDeviceProperties p; properties(devices[i],&p);
            printf("device=%s; type=%u; vulkan=%u.%u.%u\n",p.deviceName,p.deviceType,
                VK_VERSION_MAJOR(p.apiVersion),VK_VERSION_MINOR(p.apiVersion),VK_VERSION_PATCH(p.apiVersion));
            if (p.deviceType == VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU || p.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) hardware++;
            uint32_t n=0; extensions(devices[i],NULL,&n,NULL);
            VkExtensionProperties *e=calloc(n ? n : 1,sizeof(*e));
            if (e && extensions(devices[i],NULL,&n,e)==VK_SUCCESS)
                for(uint32_t j=0;j<n;j++)
                    if(strstr(e[j].extensionName,"external_memory") || strstr(e[j].extensionName,"timeline_semaphore") || strstr(e[j].extensionName,"robustness2"))
                        printf("extension=%s\n",e[j].extensionName);
            free(e);
            if(features) {
                VkPhysicalDeviceRobustness2FeaturesEXT robust={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT};
                VkPhysicalDeviceFeatures2 f={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,.pNext=&robust};
                features(devices[i],&f);
                printf("nullDescriptor=%u; robustBufferAccess2=%u; geometryShader=%u\n",robust.nullDescriptor,robust.robustBufferAccess2,f.features.geometryShader);
            }
        }
    }
    free(devices); destroy(instance,NULL); dlclose(library);
    return hardware ? 0 : 1;
}
