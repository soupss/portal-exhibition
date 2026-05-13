#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <webgpu/webgpu.h>
#include <emscripten.h>
#include <emscripten/html5.h>

typedef struct {
    float x;
    float y;
} Vec2;

typedef struct {
    float x;
    float y;
    float z;
    float _pad;
} Vec3;

typedef struct {
    Vec3 pos;
    Vec3 right;
    Vec3 forward;
    Vec3 up;
} Camera;

typedef struct {
    Vec2 resolution;
    float t;
    float t_start;
    Camera camera;
    Vec3 camera_pos_prev;
} UniformData;

typedef struct {
    bool w;
    bool a;
    bool s;
    bool d;
    bool shift;
    bool space;
    bool control;

    float mouse_dx;
    float mouse_dy;
} Input;

typedef struct {
    Vec2 resolution;
    float t_start;
    Input input;
    Camera camera;

    WGPUDevice device;
    WGPUQueue queue;
    WGPUSurface surface;
    WGPUTextureFormat surface_format;

    WGPUPipelineLayout pll_compute;
    WGPUPipelineLayout pll_render;

    WGPUComputePipeline pl_compute;
    WGPURenderPipeline pl_render;

    WGPUBuffer b_uniform;
    WGPUBindGroup bg_compute;
    WGPUBindGroup bg_render;
    WGPUBindGroup bg_uniform;
} State;

State *global_state; // needed for hot reload

float vec3_length(Vec3 v) {
    return sqrtf(v.x * v.x + v.y * v.y + v.z * v.z);
}

Vec3 vec3_normalize(Vec3 v) {
    float len = vec3_length(v);
    if (len == 0.0f) return (Vec3){0.0, 0.0, 0.0, 0.0};
    return (Vec3){v.x / len, v.y / len, v.z / len, 0.0};
}

Vec3 vec3_cross(Vec3 a, Vec3 b) {
    return (Vec3){
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x,
        0.0f
    };
}

EM_BOOL on_key_down(int event_type, const EmscriptenKeyboardEvent *e, void *userdata) {
    State *s = (State*)userdata;

    if (strcmp(e->code, "KeyW") == 0) s->input.w = true;
    if (strcmp(e->code, "KeyA") == 0) s->input.a = true;
    if (strcmp(e->code, "KeyS") == 0) s->input.s = true;
    if (strcmp(e->code, "KeyD") == 0) s->input.d = true;
    if (strcmp(e->code, "ShiftLeft") == 0) s->input.shift = true;
    if (strcmp(e->code, "Space") == 0) s->input.space = true;
    if (strcmp(e->code, "ControlLeft") == 0) s->input.control = true;
    else return EM_FALSE;

    return EM_TRUE;
}

EM_BOOL on_key_up(int event_type, const EmscriptenKeyboardEvent *e, void *userdata) {
    State *s = (State*)userdata;

    if (strcmp(e->code, "KeyW") == 0) s->input.w = false;
    if (strcmp(e->code, "KeyA") == 0) s->input.a = false;
    if (strcmp(e->code, "KeyS") == 0) s->input.s = false;
    if (strcmp(e->code, "KeyD") == 0) s->input.d = false;
    if (strcmp(e->code, "ShiftLeft") == 0) s->input.shift = false;
    if (strcmp(e->code, "Space") == 0) s->input.space = false;
    if (strcmp(e->code, "ControlLeft") == 0) s->input.control = false;
    else return EM_FALSE;

    return EM_TRUE;
}

EM_BOOL on_mouse_down(int event_type, const EmscriptenMouseEvent *e, void *userdata) {
    emscripten_request_pointerlock("#canvas", EM_FALSE);
    return EM_TRUE;
}

EM_BOOL on_mouse_move(int event_type, const EmscriptenMouseEvent *e, void *userdata) {
    State *s = (State*)userdata;

    s->input.mouse_dx = (float)e->movementX;
    s->input.mouse_dy = (float)e->movementY;

    return EM_TRUE;
}

void process_input(Input *input, Camera *camera, float dt) {
    EmscriptenPointerlockChangeEvent status;
    emscripten_get_pointerlock_status(&status);

    if (status.isActive) {
        // handle mouse
        float sensitivity = 0.002;

        if (input->mouse_dx != 0.0 || input->mouse_dy != 0.0) {
            static float yaw = 0.0;
            static float pitch = 0.0;

            yaw += input->mouse_dx * sensitivity;
            pitch -= input->mouse_dy * sensitivity;

            float a = M_PI/2.0 - 0.001;
            if (pitch < -a) pitch = -a;
            if (pitch > a) pitch = a;

            Vec3 forward;
            forward.x = sinf(yaw) * cosf(pitch);
            forward.y = sinf(pitch);
            forward.z = -cosf(yaw) * cosf(pitch);
            camera->forward = vec3_normalize(forward);

            Vec3 world_up = {0.0, 1.0, 0.0, 0.0};
            camera->right = vec3_normalize(vec3_cross(camera->forward, world_up));

            camera->up = vec3_normalize(vec3_cross(camera->right, camera->forward));
        }

        // handle keyboard
        float speed = 10.0 * dt;
        if (input->shift) speed *= 5.0;
        if (input->w) {
            camera->pos.x += camera->forward.x * speed;
            camera->pos.y += camera->forward.y * speed;
            camera->pos.z += camera->forward.z * speed;
        }
        if (input->s) {
            camera->pos.x -= camera->forward.x * speed;
            camera->pos.y -= camera->forward.y * speed;
            camera->pos.z -= camera->forward.z * speed;
        }
        if (input->a) {
            camera->pos.x -= camera->right.x * speed;
            camera->pos.y -= camera->right.y * speed;
            camera->pos.z -= camera->right.z * speed;
        }
        if (input->d) {
            camera->pos.x += camera->right.x * speed;
            camera->pos.y += camera->right.y * speed;
            camera->pos.z += camera->right.z * speed;
        }
        if (input->space) camera->pos.y += speed;
        if (input->control) camera->pos.y -= speed;
    }

    input->mouse_dx = 0.0;
    input->mouse_dy = 0.0;
}

char* load_shader(const char* filename) {
    FILE* file = fopen(filename, "rb");
    if (!file) return NULL;
    fseek(file, 0, SEEK_END);
    long length = ftell(file);
    fseek(file, 0, SEEK_SET);
    char* buffer = (char*)malloc(length + 1);
    if (buffer) {
        fread(buffer, 1, length, file);
        buffer[length] = '\0';
    }
    fclose(file);
    return buffer;
}

EMSCRIPTEN_KEEPALIVE void build_pipelines() {
    State *s = global_state;
    // load shaders
    char* code_compute = load_shader("shaders/compute.wgsl");
    char* code_vertex = load_shader("shaders/vertex.wgsl");
    char* code_fragment = load_shader("shaders/fragment.wgsl");

    if (!code_compute || !code_vertex || !code_fragment) {
        printf("One or more shader files failed to load!\n");
        if (code_compute) free(code_compute);
        if (code_vertex) free(code_vertex);
        if (code_fragment) free(code_fragment);
        return;
    }

    WGPUShaderModuleWGSLDescriptor sm_c_wgsl = {
        .chain.sType = WGPUSType_ShaderModuleWGSLDescriptor,
        .code = code_compute
    };
    WGPUShaderModuleDescriptor sm_c_desc = {
        .nextInChain = (const WGPUChainedStruct*)&sm_c_wgsl
    };
    WGPUShaderModule sm_compute = wgpuDeviceCreateShaderModule(s->device, &sm_c_desc);

    WGPUShaderModuleWGSLDescriptor sm_v_wgsl = {
        .chain.sType = WGPUSType_ShaderModuleWGSLDescriptor,
        .code = code_vertex
    };
    WGPUShaderModuleDescriptor sm_v_desc = {
        .nextInChain = (const WGPUChainedStruct*)&sm_v_wgsl
    };
    WGPUShaderModule sm_vertex = wgpuDeviceCreateShaderModule(s->device, &sm_v_desc);

    WGPUShaderModuleWGSLDescriptor sm_f_wgsl = {
        .chain.sType = WGPUSType_ShaderModuleWGSLDescriptor,
        .code = code_fragment
    };
    WGPUShaderModuleDescriptor sm_f_desc = {
        .nextInChain = (const WGPUChainedStruct*)&sm_f_wgsl
    };
    WGPUShaderModule sm_fragment = wgpuDeviceCreateShaderModule(s->device, &sm_f_desc);

    free(code_compute);
    free(code_vertex);
    free(code_fragment);

    if(s->pl_compute) wgpuComputePipelineRelease(s->pl_compute);
    if(s->pl_render) wgpuRenderPipelineRelease(s->pl_render);

    // create compute pipeline
    WGPUComputePipelineDescriptor pl_c_desc = {
        .layout = s->pll_compute,
        .compute = {
            .module = sm_compute,
            .entryPoint = "main"
        }
    };
    s->pl_compute = wgpuDeviceCreateComputePipeline(s->device, &pl_c_desc);

    // create render pipeline
    WGPUColorTargetState color_target = {
        .format = s->surface_format,
        .blend = NULL,
        .writeMask = WGPUColorWriteMask_All
    };
    WGPUFragmentState fragment_state = {
        .module = sm_fragment,
        .entryPoint = "main",
        .targetCount = 1,
        .targets = &color_target
    };

    WGPURenderPipelineDescriptor pl_r_desc = {
        .layout = s->pll_render,
        .vertex = {
            .module = sm_vertex,
            .entryPoint = "main",
            .bufferCount = 0
        },
        .fragment = &fragment_state,
        .primitive = {
            .topology = WGPUPrimitiveTopology_TriangleList
        },
        .multisample = {
            .count = 1,
            .mask = 0xFFFFFFFF
        }
    };
    s->pl_render = wgpuDeviceCreateRenderPipeline(s->device, &pl_r_desc);

    wgpuShaderModuleRelease(sm_compute);
    wgpuShaderModuleRelease(sm_vertex);
    wgpuShaderModuleRelease(sm_fragment);

    printf("Pipelines build successful\n");
}

void show_fps(double t) {
    static double t_last = 0.0;
    static int frames = 0;
    if (t_last == 0.0) t_last = t;
    frames++;

    if (t - t_last >= 0.1) {
        if (frames < 10) return;
        float dt = t - t_last;
        float fps = frames / dt;

        EM_ASM({
            const fps = $0;
            const t = $1;

            document.getElementById('fps-counter').innerText = Math.round(fps);

            let list = window.fps_list;
            list.push([fps, t]);

            if (list.length > 400) {
                list.shift();
            }
        }, fps, t);

        frames = 0;
        t_last = t;
    }
}

void loop(void* userdata) {
    State* s = (State*)userdata;

    double t = emscripten_get_now() / 1000.0;
    static double t_prev = 0.0;
    if (t_prev == 0.0) t_prev = t;
    float dt = t - t_prev;
    t_prev = t;

    show_fps(t);

    Vec3 camera_pos_prev = s->camera.pos;

    process_input(&s->input, &s->camera, dt);

    UniformData ud = {
        .resolution = s->resolution,
        .t = t,
        .t_start = s->t_start,
        .camera = s->camera,
        .camera_pos_prev = camera_pos_prev
    };
    wgpuQueueWriteBuffer(s->queue, s->b_uniform, 0, &ud, sizeof(UniformData));

    WGPUSurfaceTexture surface_texture;
    wgpuSurfaceGetCurrentTexture(s->surface, &surface_texture);
    WGPUTextureView view = wgpuTextureCreateView(surface_texture.texture, NULL);
    WGPUCommandEncoder encoder = wgpuDeviceCreateCommandEncoder(s->device, NULL);

    // compute pass
    WGPUComputePassEncoder pass_compute = wgpuCommandEncoderBeginComputePass(encoder, NULL);
    wgpuComputePassEncoderSetPipeline(pass_compute, s->pl_compute);
    wgpuComputePassEncoderSetBindGroup(pass_compute, 0, s->bg_compute, 0, NULL);
    wgpuComputePassEncoderSetBindGroup(pass_compute, 1, s->bg_uniform, 0, NULL);

    float wg_x = ceilf(s->resolution.x / 16.0);
    float wg_y = ceilf(s->resolution.y / 16.0);
    wgpuComputePassEncoderDispatchWorkgroups(pass_compute, wg_x, wg_y, 1);
    wgpuComputePassEncoderEnd(pass_compute);

    // render pass
    WGPURenderPassColorAttachment color_attachment = {
        .view = view,
        .loadOp = WGPULoadOp_Clear,
        .storeOp = WGPUStoreOp_Store,
        .clearValue = {1.0, 0.0, 0.0, 1.0},
        .depthSlice = WGPU_DEPTH_SLICE_UNDEFINED
    };
    WGPURenderPassDescriptor pass_r_desc = {
        .colorAttachmentCount = 1,
        .colorAttachments = &color_attachment
    };

    WGPURenderPassEncoder pass_render = wgpuCommandEncoderBeginRenderPass(encoder, &pass_r_desc);
    wgpuRenderPassEncoderSetPipeline(pass_render, s->pl_render);
    wgpuRenderPassEncoderSetBindGroup(pass_render, 0, s->bg_render, 0, NULL);
    wgpuRenderPassEncoderSetBindGroup(pass_render, 1, s->bg_uniform, 0, NULL);
    wgpuRenderPassEncoderDraw(pass_render, 6, 1, 0, 0);
    wgpuRenderPassEncoderEnd(pass_render);

    WGPUCommandBuffer commands = wgpuCommandEncoderFinish(encoder, NULL);
    wgpuQueueSubmit(s->queue, 1, &commands);

    wgpuComputePassEncoderRelease(pass_compute);
    wgpuCommandBufferRelease(commands);
    wgpuRenderPassEncoderRelease(pass_render);
    wgpuCommandEncoderRelease(encoder);
    wgpuTextureViewRelease(view);
}

void on_webgpu_error(WGPUErrorType type, const char* message, void* userdata) {
    printf("WEBGPU VALIDATION ERROR: %s\n", message);
}

void on_device_request(WGPURequestDeviceStatus status, WGPUDevice device, const char* message, void* userdata) {
    State* s = (State*)userdata;

    // TODO: resize on window resize
    double w, h;
    emscripten_get_element_css_size("#canvas", &w, &h);
    s->resolution = (Vec2){(float)w, (float)h};

    s->device = device;
    s->queue = wgpuDeviceGetQueue(s->device);

    wgpuDeviceSetUncapturedErrorCallback(s->device, on_webgpu_error, NULL);

    WGPUSurfaceConfiguration config = {
        .device = s->device,
        .format = s->surface_format,
        .usage = WGPUTextureUsage_RenderAttachment,
        .alphaMode = WGPUCompositeAlphaMode_Auto,
        .width = (uint32_t)s->resolution.x,
        .height = (uint32_t)s->resolution.y,
        .presentMode = WGPUPresentMode_Fifo
    };
    wgpuSurfaceConfigure(s->surface, &config);

    // compute bind group layout
    WGPUBindGroupLayoutEntry bgl_c_entries[2] = {
        {
            .binding = 0,
            .visibility = WGPUShaderStage_Compute,
            .storageTexture = {
                .access = WGPUStorageTextureAccess_WriteOnly,
                .format = WGPUTextureFormat_RGBA8Unorm,
                .viewDimension = WGPUTextureViewDimension_2D
            }
        },
        {
            .binding = 1,
            .visibility = WGPUShaderStage_Compute,
            .buffer = {
                .type = WGPUBufferBindingType_Storage
            }
        }
    };
    WGPUBindGroupLayoutDescriptor bgl_c_desc = {
        .entryCount = 2,
        .entries = bgl_c_entries
    };
    WGPUBindGroupLayout bgl_compute = wgpuDeviceCreateBindGroupLayout(s->device, &bgl_c_desc);

    // render bind group layout
    WGPUBindGroupLayoutEntry bgl_r_entries[2] = {
        {
            .binding = 0,
            .visibility = WGPUShaderStage_Fragment,
            .texture = {
                .sampleType = WGPUTextureSampleType_Float,
                .viewDimension = WGPUTextureViewDimension_2D,
                .multisampled = false,
            }
        },
        {
            .binding = 1,
            .visibility = WGPUShaderStage_Fragment,
            .sampler = {
                .type = WGPUSamplerBindingType_Filtering
            }
        }
    };
    WGPUBindGroupLayoutDescriptor bgl_r_desc = {
        .entryCount = 2,
        .entries = bgl_r_entries
    };
    WGPUBindGroupLayout bgl_render = wgpuDeviceCreateBindGroupLayout(s->device, &bgl_r_desc);

    // uniform bind group layout
    WGPUBindGroupLayoutEntry bgl_u_entries[1] = {
        {
            .binding = 0,
            .visibility = WGPUShaderStage_Compute | WGPUShaderStage_Fragment,
            .buffer = {
                .type = WGPUBufferBindingType_Uniform
            }
        }
    };
    WGPUBindGroupLayoutDescriptor bgl_u_desc = {
        .entryCount = 1,
        .entries = bgl_u_entries
    };
    WGPUBindGroupLayout bgl_uniform = wgpuDeviceCreateBindGroupLayout(s->device, &bgl_u_desc);

    // pipeline layouts
    WGPUBindGroupLayout bgls_compute[2] = {
        bgl_compute,
        bgl_uniform
    };
    WGPUPipelineLayoutDescriptor pll_c_desc = {
        .bindGroupLayoutCount = 2,
        .bindGroupLayouts = bgls_compute
    };
    s->pll_compute = wgpuDeviceCreatePipelineLayout(s->device, &pll_c_desc);

    WGPUBindGroupLayout bgls_render[2] = {
        bgl_render,
        bgl_uniform
    };
    WGPUPipelineLayoutDescriptor pll_r_desc = {
        .bindGroupLayoutCount = 2,
        .bindGroupLayouts = bgls_render
    };
    s->pll_render = wgpuDeviceCreatePipelineLayout(s->device, &pll_r_desc);

    build_pipelines();

    // create rendertarget texture
    WGPUTextureDescriptor t_rendertarget_desc = {
        .usage = WGPUTextureUsage_StorageBinding | WGPUTextureUsage_TextureBinding,
        .dimension = WGPUTextureDimension_2D,
        .size = {s->resolution.x, s->resolution.y, 1},
        .format = WGPUTextureFormat_RGBA8Unorm,
        .mipLevelCount = 1,
        .sampleCount = 1,
        .viewFormatCount = 0,
        .viewFormats = NULL
    };
    WGPUTexture t_rendertarget = wgpuDeviceCreateTexture(s->device, &t_rendertarget_desc);
    WGPUTextureView tv_rendertarget = wgpuTextureCreateView(t_rendertarget, NULL);

    // create sampler
    WGPUSamplerDescriptor s_rendertarget_desc = {
        .addressModeU = WGPUAddressMode_ClampToEdge,
        .addressModeV = WGPUAddressMode_ClampToEdge,
        .addressModeW = WGPUAddressMode_ClampToEdge,
        .magFilter = WGPUFilterMode_Linear,
        .minFilter = WGPUFilterMode_Linear,
        .mipmapFilter = WGPUMipmapFilterMode_Linear,
        .lodMinClamp = 0.0f,
        .lodMaxClamp = 1.0f,
        .maxAnisotropy = 1
    };
    WGPUSampler s_rendertarget = wgpuDeviceCreateSampler(s->device, &s_rendertarget_desc);

    // create state buffer
    uint64_t b_state_size = (uint64_t)sizeof(int);
    WGPUBufferDescriptor b_state_desc = {
        .size = b_state_size,
        .usage = WGPUBufferUsage_Storage | WGPUBufferUsage_CopyDst | WGPUBufferUsage_CopySrc,
        .mappedAtCreation = false
    };
    WGPUBuffer b_state = wgpuDeviceCreateBuffer(s->device, &b_state_desc);

    int world_start = 0;
    wgpuQueueWriteBuffer(s->queue, b_state, 0, &world_start, b_state_size);

    // create uniform buffer
    WGPUBufferDescriptor b_uniform_desc = {
        .size = sizeof(UniformData),
        .usage = WGPUBufferUsage_Uniform | WGPUBufferUsage_CopyDst,
        .mappedAtCreation = false
    };
    s->b_uniform = wgpuDeviceCreateBuffer(s->device, &b_uniform_desc);

    // create compute bind group
    WGPUBindGroupEntry bg_c_entries[2] = {
        {
            .binding = 0,
            .textureView = tv_rendertarget
        },
        {
            .binding = 1,
            .buffer = b_state,
            .offset = 0,
            .size = b_state_size
        }
    };
    WGPUBindGroupDescriptor bg_c_desc = {
        .layout = bgl_compute,
        .entryCount = 2,
        .entries = bg_c_entries
    };
    s->bg_compute = wgpuDeviceCreateBindGroup(s->device, &bg_c_desc);

    // create render bind group
    WGPUBindGroupEntry bg_r_entries[2] = {
        {
            .binding = 0,
            .textureView = tv_rendertarget
        },
        {
            .binding = 1,
            .sampler = s_rendertarget
        }
    };
    WGPUBindGroupDescriptor bg_r_desc = {
        .layout = bgl_render,
        .entryCount = 2,
        .entries = bg_r_entries
    };
    s->bg_render = wgpuDeviceCreateBindGroup(s->device, &bg_r_desc);

    // create uniform bind group
    WGPUBindGroupEntry bg_u_entries[1] = {
        {
            .binding = 0,
            .buffer = s->b_uniform,
            .offset = 0,
            .size = sizeof(UniformData)
        }
    };
    WGPUBindGroupDescriptor bg_u_desc = {
        .layout = bgl_uniform,
        .entryCount = 1,
        .entries = bg_u_entries
    };
    s->bg_uniform = wgpuDeviceCreateBindGroup(s->device, &bg_u_desc);

    emscripten_set_keydown_callback(EMSCRIPTEN_EVENT_TARGET_WINDOW, s, EM_TRUE, on_key_down);
    emscripten_set_keyup_callback(EMSCRIPTEN_EVENT_TARGET_WINDOW, s, EM_TRUE, on_key_up);
    emscripten_set_mousedown_callback("#canvas", s, EM_TRUE, on_mouse_down);
    emscripten_set_mousemove_callback("#canvas", s, EM_TRUE, on_mouse_move);

    emscripten_set_main_loop_arg(loop, s, 0, false);
}

void on_adapter_request(WGPURequestAdapterStatus status, WGPUAdapter adapter, const char* message, void* userdata) {
    State* s = (State*)userdata;
    s->surface_format = wgpuSurfaceGetPreferredFormat(s->surface, adapter);

    wgpuAdapterRequestDevice(adapter, NULL, on_device_request, s);
}

int main() {
    // fix a stupid casting bug
    EM_ASM({
        const originalWriteBuffer = GPUQueue.prototype.writeBuffer;
        GPUQueue.prototype.writeBuffer = function(buffer, bufferOffset, data, dataOffset, size) {
            return originalWriteBuffer.call(this,
                buffer,
                typeof bufferOffset === 'bigint' ? Number(bufferOffset) : bufferOffset,
                data,
                typeof dataOffset === 'bigint' ? Number(dataOffset) : dataOffset,
                typeof size === 'bigint' ? Number(size) : size
            );
        };
    });

    State* s = (State*)malloc(sizeof(State));
    memset(s, 0, sizeof(State));
    global_state = s;

    double t_start_sec = emscripten_date_now()/1000.0;
    s->t_start = (float)fmod(t_start_sec, 10000);

    s->camera.pos = (Vec3){.x = 0.0, .y = 3.5, .z = 10.0};
    s->camera.right = (Vec3){.x = 1.0, .y = 0.0, .z = 0.0};
    s->camera.forward = (Vec3){.x = 0.0, .y = 0.0, .z = -1.0};
    s->camera.up = (Vec3){.x = 0.0, .y = 1.0, .z = 0.0};

    WGPUInstance instance = wgpuCreateInstance(NULL);
    WGPUSurfaceDescriptorFromCanvasHTMLSelector canvas_desc = {
        .chain.sType = WGPUSType_SurfaceDescriptorFromCanvasHTMLSelector,
        .selector = "#canvas"
    };
    WGPUSurfaceDescriptor surface_desc = {
        .nextInChain = (const WGPUChainedStruct*)&canvas_desc
    };

    s->surface = wgpuInstanceCreateSurface(instance, &surface_desc);

    wgpuInstanceRequestAdapter(instance, NULL, on_adapter_request, s);
    return 0;
}
