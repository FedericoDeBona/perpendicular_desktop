/* One bounded transfer/readback against an explicitly selected private ICD.
 * This does not install a driver or qualify WSI/OpenGL/application rendering. */
#define WIN32_LEAN_AND_MEAN
#define VK_NO_PROTOTYPES
#include <windows.h>
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>

#define INST(name) PFN_##name name = (PFN_##name)get(instance, #name)
#define DEV(name) PFN_##name name = (PFN_##name)get_device(device, #name)
#define CHECK(call) do { VkResult r = (call); if (r != VK_SUCCESS) { \
    printf("%s: VkResult=%d\n", #call, r); success=0; goto done; } } while (0)

int main(int argc, char **argv)
{
    const int image_copy = argc == 3 && !strcmp(argv[2], "--image");
    const int multi = image_copy || (argc == 3 && !strcmp(argv[2], "--multi"));
    if (argc != 2 && !multi) return 2;
    const unsigned count = multi ? 4 : 1;
    const VkDeviceSize sizes[4] = {multi ? 2095104 : 4096, 2095104, 2095104, 6144};
    HMODULE library = LoadLibraryA(argv[1]);
    if (!library) { printf("LoadLibrary: %lu\n", GetLastError()); return 1; }
    PFN_vkGetInstanceProcAddr get = (PFN_vkGetInstanceProcAddr)GetProcAddress(library, "vk_icdGetInstanceProcAddr");
    if (!get) { FreeLibrary(library); return 1; }
    VkInstance instance = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;
    VkBuffer buffers[4] = {0};
    VkDeviceMemory memories[4] = {0};
    VkImage image = VK_NULL_HANDLE;
    VkDeviceMemory image_memory = VK_NULL_HANDLE;
    VkCommandPool pool = VK_NULL_HANDLE;
    void *mapped[4] = {0};
    uint32_t types[4] = {0};
    int success = 0;
    PFN_vkCreateInstance create = (PFN_vkCreateInstance)get(NULL, "vkCreateInstance");
    VkApplicationInfo app = {.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion=VK_API_VERSION_1_1};
    VkInstanceCreateInfo ci = {.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo=&app};
    if (create(&ci, NULL, &instance) != VK_SUCCESS) { FreeLibrary(library); return 1; }
    INST(vkDestroyInstance);
    INST(vkEnumeratePhysicalDevices);
    INST(vkGetPhysicalDeviceProperties);
    INST(vkGetPhysicalDeviceQueueFamilyProperties);
    INST(vkGetPhysicalDeviceMemoryProperties);
    INST(vkCreateDevice);
    INST(vkGetDeviceProcAddr);
    PFN_vkGetDeviceProcAddr get_device = vkGetDeviceProcAddr;
    uint32_t n = 4;
    VkPhysicalDevice devices[4];
    if (vkEnumeratePhysicalDevices(instance, &n, devices) != VK_SUCCESS || !n) goto instance_done;
    VkPhysicalDevice physical = VK_NULL_HANDLE;
    for (uint32_t i=0; i<n; i++) {
        VkPhysicalDeviceProperties p;
        vkGetPhysicalDeviceProperties(devices[i], &p);
        if (p.deviceType == VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU || p.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) {
            physical=devices[i]; printf("GPU=%s; type=%u\n", p.deviceName, p.deviceType); break;
        }
    }
    if (!physical) goto instance_done;
    uint32_t queue_count=16, family=UINT32_MAX;
    VkQueueFamilyProperties queues[16];
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &queue_count, queues);
    for (uint32_t i=0; i<queue_count; i++)
        if (queues[i].queueCount && (queues[i].queueFlags & VK_QUEUE_GRAPHICS_BIT)) { family=i; break; }
    if (family==UINT32_MAX) goto instance_done;
    float priority=1;
    VkDeviceQueueCreateInfo qi={.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex=family, .queueCount=1, .pQueuePriorities=&priority};
    VkDeviceCreateInfo di={.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount=1, .pQueueCreateInfos=&qi};
    VkResult created=vkCreateDevice(physical, &di, NULL, &device);
    if (created != VK_SUCCESS) { printf("vkCreateDevice=%d\n",created); goto instance_done; }
    DEV(vkDestroyDevice); DEV(vkGetDeviceQueue); DEV(vkCreateBuffer); DEV(vkDestroyBuffer);
    DEV(vkGetBufferMemoryRequirements); DEV(vkAllocateMemory); DEV(vkFreeMemory);
    DEV(vkBindBufferMemory); DEV(vkMapMemory); DEV(vkUnmapMemory); DEV(vkInvalidateMappedMemoryRanges);
    DEV(vkCreateCommandPool); DEV(vkDestroyCommandPool); DEV(vkAllocateCommandBuffers);
    DEV(vkBeginCommandBuffer); DEV(vkEndCommandBuffer); DEV(vkCmdFillBuffer);
    DEV(vkCmdPipelineBarrier); DEV(vkQueueSubmit); DEV(vkQueueWaitIdle);
    DEV(vkCreateImage); DEV(vkDestroyImage); DEV(vkGetImageMemoryRequirements);
    DEV(vkBindImageMemory); DEV(vkCmdClearColorImage); DEV(vkCmdCopyImageToBuffer);
    VkPhysicalDeviceMemoryProperties props;
    vkGetPhysicalDeviceMemoryProperties(physical,&props);
    for (unsigned b=0; b<count; b++) {
        VkBufferCreateInfo bi={.sType=VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size=sizes[b], .usage=VK_BUFFER_USAGE_TRANSFER_DST_BIT};
        CHECK(vkCreateBuffer(device, &bi, NULL, &buffers[b]));
        VkMemoryRequirements requirements;
        vkGetBufferMemoryRequirements(device, buffers[b], &requirements);
        uint32_t type=UINT32_MAX;
        for (uint32_t i=0; i<props.memoryTypeCount; i++)
            if ((requirements.memoryTypeBits & (1u<<i)) && (props.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) { type=i; break; }
        if (type==UINT32_MAX) goto done;
        types[b]=type;
        VkMemoryAllocateInfo ai={.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize=requirements.size, .memoryTypeIndex=type};
        CHECK(vkAllocateMemory(device,&ai,NULL,&memories[b]));
        CHECK(vkBindBufferMemory(device,buffers[b],memories[b],0));
        if (multi) {
            CHECK(vkMapMemory(device,memories[b],0,VK_WHOLE_SIZE,0,&mapped[b]));
            memset(mapped[b],0x21+b,(size_t)sizes[b]);
            if (!(props.memoryTypes[type].propertyFlags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {
                DEV(vkFlushMappedMemoryRanges);
                VkMappedMemoryRange range={.sType=VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE, .memory=memories[b], .size=VK_WHOLE_SIZE};
                CHECK(vkFlushMappedMemoryRanges(device,1,&range));
            }
        }
    }
    if (image_copy) {
        VkImageCreateInfo ii={.sType=VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType=VK_IMAGE_TYPE_2D, .format=VK_FORMAT_R8G8B8A8_UNORM,
            .extent={1536,1024,1}, .mipLevels=1, .arrayLayers=1,
            .samples=VK_SAMPLE_COUNT_1_BIT, .tiling=VK_IMAGE_TILING_OPTIMAL,
            .usage=VK_IMAGE_USAGE_TRANSFER_DST_BIT|VK_IMAGE_USAGE_TRANSFER_SRC_BIT};
        CHECK(vkCreateImage(device,&ii,NULL,&image));
        VkMemoryRequirements req;
        vkGetImageMemoryRequirements(device,image,&req);
        uint32_t type=UINT32_MAX;
        for (uint32_t i=0; i<props.memoryTypeCount; i++)
            if (req.memoryTypeBits & (1u<<i)) { type=i; break; }
        if (type==UINT32_MAX) goto done;
        VkMemoryAllocateInfo ai={.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize=req.size, .memoryTypeIndex=type};
        CHECK(vkAllocateMemory(device,&ai,NULL,&image_memory));
        CHECK(vkBindImageMemory(device,image,image_memory,0));
    }
    VkCommandPoolCreateInfo pi={.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex=family};
    CHECK(vkCreateCommandPool(device,&pi,NULL,&pool));
    VkCommandBufferAllocateInfo cai={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool=pool, .level=VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount=1};
    VkCommandBuffer command;
    CHECK(vkAllocateCommandBuffers(device,&cai,&command));
    VkCommandBufferBeginInfo begin={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    CHECK(vkBeginCommandBuffer(command,&begin));
    if (image_copy) {
        VkImageSubresourceRange range={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};
        VkImageMemoryBarrier ib={.sType=VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .dstAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT, .oldLayout=VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, .srcQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED, .image=image, .subresourceRange=range};
        vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,NULL,0,NULL,1,&ib);
        VkClearColorValue red={.float32={1,0,0,1}};
        vkCmdClearColorImage(command,image,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,&red,1,&range);
        ib.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;
        ib.dstAccessMask=VK_ACCESS_TRANSFER_READ_BIT;
        ib.oldLayout=ib.newLayout;
        ib.newLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,NULL,0,NULL,1,&ib);
        for (unsigned b=0; b<count; b++) {
            VkBufferImageCopy region={.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1},
                .imageOffset={0,341*b,0}, .imageExtent={1536,b==3 ? 1 : 341,1}};
            vkCmdCopyImageToBuffer(command,image,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,buffers[b],1,&region);
        }
    } else {
        for (unsigned b=0; b<count; b++)
            vkCmdFillBuffer(command,buffers[b],0,sizes[b],0x1234abcd+b);
    }
    VkMemoryBarrier barrier={.sType=VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask=VK_ACCESS_HOST_READ_BIT};
    vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,1,&barrier,0,NULL,0,NULL);
    CHECK(vkEndCommandBuffer(command));
    VkQueue queue;
    vkGetDeviceQueue(device,family,0,&queue);
    VkSubmitInfo submit={.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount=1, .pCommandBuffers=&command};
    CHECK(vkQueueSubmit(queue,1,&submit,VK_NULL_HANDLE));
    CHECK(vkQueueWaitIdle(queue));
    success=1;
    for (unsigned b=0; b<count; b++) {
        if (!mapped[b]) CHECK(vkMapMemory(device,memories[b],0,VK_WHOLE_SIZE,0,&mapped[b]));
        if (!(props.memoryTypes[types[b]].propertyFlags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {
            VkMappedMemoryRange range={.sType=VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE, .memory=memories[b], .size=VK_WHOLE_SIZE};
            CHECK(vkInvalidateMappedMemoryRanges(device,1,&range));
        }
        size_t bad=0;
        const uint32_t expected=image_copy ? 0xff0000ff : 0x1234abcd+b;
        for (size_t i=0; i<sizes[b]/4; i++) bad+=((uint32_t *)mapped[b])[i] != expected;
        if (bad) success=0;
        printf("Buffer %u: bytes=%llu different_words=%zu first=%08x last=%08x\n", b,
               (unsigned long long)sizes[b], bad, ((uint32_t *)mapped[b])[0],
               ((uint32_t *)mapped[b])[sizes[b]/4-1]);
    }
    printf("GPU fill and readback: %s (%u buffer%s)\n",success ? "PASS" : "FAIL",count,count==1 ? "" : "s");
done:
    for (unsigned b=0; b<count; b++) if(mapped[b]) vkUnmapMemory(device,memories[b]);
    if(pool) vkDestroyCommandPool(device,pool,NULL);
    if(image) vkDestroyImage(device,image,NULL);
    if(image_memory) vkFreeMemory(device,image_memory,NULL);
    for (unsigned b=0; b<count; b++) {
        if(buffers[b]) vkDestroyBuffer(device,buffers[b],NULL);
        if(memories[b]) vkFreeMemory(device,memories[b],NULL);
    }
    vkDestroyDevice(device,NULL);
instance_done:
    vkDestroyInstance(instance,NULL);
    FreeLibrary(library);
    return success ? 0 : 1;
}
