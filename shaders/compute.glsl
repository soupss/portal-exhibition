#version 450

// #define DEBUG

#define NULL -1

#define WORLD_HUB 0
#define WORLD_SUB_FRACTAL 1
#define WORLD_SUB_LAVALAMP 2
#define WORLD_SUB_MOUNTAINS 3

#define NUM_PORTALS 3

const int SUB_WORLDS[NUM_PORTALS] = {
    WORLD_SUB_LAVALAMP,
    WORLD_SUB_FRACTAL,
    WORLD_SUB_MOUNTAINS
};

#define MATERIAL_TYPE_OPAQUE 0
#define MATERIAL_TYPE_PORTAL 1

#define PI 3.1415926535897932384626433832795
#define D_MAX 150
#define STEPS_MAX 256

#define PORTAL_WIDTH 2.3
#define PORTAL_HEIGHT 3.7

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(rgba8, set = 0, binding = 0) uniform writeonly image2D rendertarget;

layout(set = 0, binding = 1, std430) buffer state {
    int world_global;
};

int world_ray;

struct Camera {
    vec3 pos;
    vec3 right;
    vec3 forward;
    vec3 up;
};

layout(set = 1, binding = 0, std140) uniform frame {
    vec2 resolution;
    float t;
    float t_start;
    Camera camera;
    vec3 camera_pos_prev;
} u;

struct Material {
    int type;
    vec3 albedo;
    float roughness;
    float metallic;
};

struct Light {
    vec3 pos;
    vec3 color;
    float strength;
};

struct Hit {
    float d;
    Material material;
    int world_target;
};

#define NULL_HIT Hit(0.0, Material(MATERIAL_TYPE_OPAQUE, vec3(1.0, 0.0, 1.0), 0.0, 0.0), NULL)

float sd_sphere(vec3 p, float r) {
    return length(p) - r;
}

float sd_plane(vec3 p, vec3 n) {
    return dot(p, n);
}

float sd_box(vec3 p, vec3 b) {
    vec3 q = abs(p) - b;
    return length(max(q,0.0)) + min(max(q.x,max(q.y,q.z)),0.0);
}

float sd_ellipsoid(vec3 p, vec3 r) {
    float k0 = length(p/r);
    float k1 = length(p/(r*r));
    return k0*(k0-1.0)/k1;
}

mat2 rotate_2d(float a) {
    float c = cos(a);
    float s = sin(a);
    return mat2(c, s, -s, c);
}

vec3 smootherstep(float edge0, float edge1, vec3 x) {
    x = clamp(x, edge0, edge1);
    return x * x * x * (x * (x * 6 - 15) + 10);
}

float sd_portal(vec3 p, vec3 n) {
    vec3 up = vec3(0.0, 1.0, 0.0);
    vec3 right = normalize(cross(up, n));

    vec3 p_local = vec3(dot(p, right), dot(p, up), dot(p, n));

    return max(
            sd_ellipsoid(p_local, vec3(PORTAL_WIDTH, PORTAL_HEIGHT, 1.0)),
            sd_box(p_local, vec3(PORTAL_WIDTH, PORTAL_HEIGHT, 1e-8))
            );
}

// TODO: avoid trig in N functions
float N(float k) {
    return fract(sin(k * 12.9898) * 43758.5453123);
}

float N31(vec3 p3) {
    p3  = fract(p3 * .1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float N21(vec2 p) {
    return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453123);
}

vec3 N23(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * vec3(.1031, .1030, .0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return fract((p3.xxy + p3.yzz) * p3.zyx);
}

vec2 N22(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * vec3(.1031, .1030, .0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy) * 2.0 - 1.0;
}

vec2 N12(float p) {
    vec3 p3 = fract(vec3(p) * vec3(.1031, .1030, .0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

vec3 N13(float p) {
    vec3 p3 = fract(vec3(p) * vec3(.1031, .1030, .0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xxy + p3.yzz) * p3.zyx);
}

vec3 N33(vec3 p3) {
    p3 = fract(p3 * vec3(.1031, .1030, .0973));
    p3 += dot(p3, p3.yxz+33.33);
    return 2.0*fract((p3.xxy + p3.yxx)*p3.zyx) - 1.0;
}

float smin(float a, float b, float k) {
    k *= 2.0;
    float x = b-a;
    return 0.5*( a+b-sqrt(x*x+k*k) );
}

// union operation for Hit
Hit u_op(Hit a, Hit b) {
    if (a.d < b.d) return a;
    else return b;
}

// cosine palette, credit to inigo quilez
vec3 palette(float k, vec3 a, vec3 b, vec3 c, vec3 d) {
    return a + b * cos(6.28318 * (c * k + d));
}

//TODO: 2d
float value_noise(vec3 p) {
    vec3 id = floor(p);
    vec3 lp = fract(p);

    lp = smootherstep(0.0, 1.0, lp);

    float n000 = N31(id);
    float n100 = N31(id + vec3(1.0, 0.0, 0.0));
    float n010 = N31(id + vec3(0.0, 1.0, 0.0));
    float n110 = N31(id + vec3(1.0, 1.0, 0.0));
    float n001 = N31(id + vec3(0.0, 0.0, 1.0));
    float n101 = N31(id + vec3(1.0, 0.0, 1.0));
    float n011 = N31(id + vec3(0.0, 1.0, 1.0));
    float n111 = N31(id + vec3(1.0, 1.0, 1.0));

    return mix(mix(mix(n000, n100, lp.x), mix(n010, n110, lp.x), lp.y),
             mix(mix(n001, n101, lp.x), mix(n011, n111, lp.x), lp.y), lp.z);
}

float noise_gradient(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);

    vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);

    vec2 g00 = N22(i + vec2(0.0, 0.0));
    vec2 g10 = N22(i + vec2(1.0, 0.0));
    vec2 g01 = N22(i + vec2(0.0, 1.0));
    vec2 g11 = N22(i + vec2(1.0, 1.0));

    float d00 = dot(g00, f - vec2(0.0, 0.0));
    float d10 = dot(g10, f - vec2(1.0, 0.0));
    float d01 = dot(g01, f - vec2(0.0, 1.0));
    float d11 = dot(g11, f - vec2(1.0, 1.0));

    float x0 = mix(d00, d10, u.x);
    float x1 = mix(d01, d11, u.x);
    float n = mix(x0, x1, u.y);

    return n;
}

float fbm(vec2 p, int octaves) {
    float n = 0.0;
    float freq = 1.0;
    float amp = 1.0;
    float amp_max = 0.0;

    const float dfreq = 2.0;
    const float damp = 0.5;
    for (int i = 0; i < octaves; i++) {
        n += noise_gradient(freq*p)*amp;
        // p *= mat2(0.8, -0.6, 0.6, 0.8);

        amp_max += amp;
        freq *= dfreq;
        amp *= damp;
    }
    return n/amp_max;
}


// get portal to "world" position and normal
// column 1 is portal position
// column 2 is portal normal
mat2x3 get_portal(int world) {
    vec3 pos, n;

    // this parametrization is too performance heavy

    // for (int i = 0; i < NUM_PORTALS; i++) {
    //     if (SUB_WORLDS[i] == world) {
    //         float t = (2 * PI * float(i)) / float(NUM_PORTALS);
    //         float r = 10.0;
    //
    //         pos = vec3(r*cos(t), 4.0, r*sin(t));
    //         n = vec3(-cos(t), 0.0, -sin(t));
    //
    //         break;
    //     }
    // }

    // so it's hardcoded

    if (world == WORLD_SUB_LAVALAMP) {
        pos = vec3(10.0, 4.0, 0.0);
        n = vec3(-1.0, 0.0, 0.0);
    }
    else if (world == WORLD_SUB_FRACTAL) {
        pos = vec3(-5.0, 4.0, 8.660254);
        n = vec3(0.5, 0.0, -0.8660254);
    }
    else if (world == WORLD_SUB_MOUNTAINS) {
        pos = vec3(-5.0, 4.0, -8.660254);
        n = vec3(0.5, 0.0, 0.8660254);
    }
    else {
        pos = vec3(0.0);
        n = vec3(0.0, 0.0, 1.0);
    }

    return mat2x3(pos, n);
}

bool portal_entered(int world) {
    mat2x3 portal = get_portal(world);
    vec3 pos = portal[0];
    vec3 n = portal[1];

    vec3 cam_pos_relative = u.camera.pos - pos;
    vec3 cam_pos_relative_prev = u.camera_pos_prev - pos;

    // camera pos in portal space
    float z = dot(cam_pos_relative, n);
    float z_prev = dot(cam_pos_relative_prev, n);

    if (sign(z) != sign(z_prev)) {
        // portal's local axes
        vec3 up = vec3(0.0, 1.0, 0.0);
        vec3 right = normalize(cross(up, n));

        float x = dot(cam_pos_relative, right);
        float y = dot(cam_pos_relative, up);

        float x2 = x*x;
        float y2 = y*y;
        float w2 = PORTAL_WIDTH*PORTAL_WIDTH;
        float h2 = PORTAL_HEIGHT*PORTAL_HEIGHT;

        bool intersects_xy = x2/w2 + y2/h2 <= 1.0;
        return intersects_xy;
    }

    return false;
}

// get world camera is in
int get_world() {
    if (world_global == WORLD_HUB) {
        for (int i = 0; i < NUM_PORTALS; i++) {
            int world = SUB_WORLDS[i];
            if (portal_entered(world)) return world;
        }
        return WORLD_HUB;
    }
    else {
        if (portal_entered(world_global)) return WORLD_HUB;
        return world_global;
    }
    return NULL;
}

vec3 get_bg(int world) {
    if (world == WORLD_HUB) return vec3(1.0);
    else if (world == WORLD_SUB_MOUNTAINS) return vec3(0.53, 0.81, 0.92);
    else return vec3(0.0);
}

Hit map_hub_s(vec3 p) {
    Hit hit;
    hit.world_target = WORLD_HUB;
    // white nothingness
    hit.d = 1e8;
    hit.material = Material(MATERIAL_TYPE_OPAQUE, vec3(1.0), 0.0, 0.0);

    return hit;
}

Hit map_hub_p(vec3 p) {
    Hit hit = map_hub_s(p);
    {
        // portal to fractal world
        mat2x3 portal = get_portal(WORLD_SUB_FRACTAL);
        vec3 portal_pos = portal[0];
        vec3 portal_n = portal[1];

        vec3 q = p - portal_pos;
        float d = sd_portal(q, portal_n);
        Material m = Material(MATERIAL_TYPE_PORTAL, vec3(1.0), 0.0, 0.0);
        hit = u_op(hit, Hit(d, m, WORLD_SUB_FRACTAL));
    }

    {
        // portal to lavalamp world
        mat2x3 portal = get_portal(WORLD_SUB_LAVALAMP);
        vec3 portal_pos = portal[0];
        vec3 portal_n = portal[1];

        vec3 q = p - portal_pos;
        float d = sd_portal(q, portal_n);
        Material m = Material(MATERIAL_TYPE_PORTAL, vec3(1.0), 0.0, 0.0);
        hit = u_op(hit, Hit(d, m, WORLD_SUB_LAVALAMP));
    }

    {
        // portal to mountains world
        mat2x3 portal = get_portal(WORLD_SUB_MOUNTAINS);
        vec3 portal_pos = portal[0];
        vec3 portal_n = portal[1];

        vec3 q = p - portal_pos;
        float d = sd_portal(q, portal_n);
        Material m = Material(MATERIAL_TYPE_PORTAL, vec3(1.0), 0.0, 0.0);
        hit = u_op(hit, Hit(d, m, WORLD_SUB_MOUNTAINS));
    }
    return hit;
}

Hit map_fractal_s(vec3 p) {
    mat2x3 portal = get_portal(WORLD_SUB_FRACTAL);
    vec3 portal_pos = portal[0];
    vec3 portal_n = portal[1];

    // project to fractal world space
    vec3 up = vec3(0.0, 1.0, 0.0);
    vec3 forward = portal_n;
    vec3 right = normalize(cross(up, forward));

    vec3 q = vec3(dot(p, right), dot(p, up), dot(p, forward));

    Hit hit;
    hit.world_target = NULL;
    {
        hit.d = sd_plane(q, vec3(0.0, 1.0, 0.0));
        hit.material = Material(MATERIAL_TYPE_OPAQUE, vec3(1.0, 0.0, 0.0), 0.0, 0.0);
    }

    {
        vec3 q = q - vec3(0.0, 3.5 + 0.35*sin(0.8*u.t), -18.0);

        float s = 11.0;
        vec2 id = round(q.xy/s);
        if (id.y < 0 || id.y > 10) return hit;
        q.xy = q.xy - s*round(id);

        q.xz *= rotate_2d(0.1 * u.t);
        q.yz *= rotate_2d(0.05 * u.t);
        q.xz *= rotate_2d(0.05 * -u.t);

        float d_bound = sd_sphere(q, 10.0);
        if (d_bound > 1.0) {
            hit.d = min(hit.d, d_bound);
        }
        else {

            // precalculate rotation matrices
            mat2 rot_xz = rotate_2d(0.2*u.t);
            mat2 rot_xy = rotate_2d(0.15*u.t);

            // kifs fractal
            float scale = 2.0;
            float scaled = 1.0;
            vec4 trap = vec4(1e10);
            for (int i = 0; i < id.y; i++) {
                q = abs(q);
                q -= vec3(1.0, 0.4, 0.7);
                q.xz *= rot_xz;
                q.xy *= rot_xy;
                q *= scale*0.8;
                scaled *= scale;
                trap = min(trap, vec4(abs(q), length(q)));
            }

            float d = sd_box(q, vec3(1.0, 1.2, 1.0));
            d /= scaled;

            vec3 color = palette(trap.z * 4.0, vec3(0.5), vec3(0.5), vec3(1.0), vec3(0.0, 0.1, 0.2));
            Material m = Material(MATERIAL_TYPE_OPAQUE, color, 0.4, 1.0);
            hit = u_op(hit, Hit(d, m, NULL));
        }
    }

    return hit;
}

Hit map_fractal_p(vec3 p) {
    Hit hit = map_fractal_s(p);
    {
        mat2x3 portal = get_portal(WORLD_SUB_FRACTAL);
        vec3 portal_pos = portal[0];
        vec3 portal_n = -portal[1];

        vec3 q = p - portal_pos;
        float d = sd_portal(q, portal_n);
        Material m = Material(MATERIAL_TYPE_PORTAL, vec3(1.0), 0.0, 0.0);
        hit = u_op(hit, Hit(d, m, WORLD_HUB));
    }
    return hit;
}

#define BLUBS 4

vec3 g_blub_pos[BLUBS];
float g_blub_r[BLUBS];

// todo: use fract() instead of sin for periodicity
void precalculate_blobs() {
    float world_height = 20.0;
    float y = world_height/2.0 + world_height * 0.7 * sin(2.0*PI*N(u.t_start) + u.t * 0.6);
    y = 5.0 + y*0.65;

    float r_blob = 3.5;

    for (int i = 0; i < BLUBS; i++) {
        vec3 rand = N23(vec2(u.t_start, float(i)));

        float r_blub_amp = r_blob*0.5*1.5;
        g_blub_r[i] = r_blob*0.5*(rand.x+0.5);
        float s = 1.2*r_blob;

        float y2 = y + s*sin(2.0*PI*rand.y + u.t*(1.5 + rand.y));
        float x = s*sin(2.0*PI*rand.x + u.t*(1.5 + rand.x));
        float z = s*sin(2.0*PI*rand.z + u.t*(1.5 + rand.z));
        g_blub_pos[i] = vec3(x, y2, z);
    }
}

Hit map_lavalamp_s(vec3 p) {
    Hit hit;
    hit.world_target = NULL;

    float world_height = 20.0;
    p.y += 4.0;
    p.x -= 35.0;
    // floor
    {
        hit.d = sd_plane(p, vec3(0.0, 1.0, 0.0));
        hit.material = Material(MATERIAL_TYPE_OPAQUE, vec3(0.0, 0.0, 1.0), 0.0, 0.0);
    }
    // roof
    {
        vec3 q = p - vec3(0.0, world_height, 0.0);
        float d = sd_plane(q, vec3(0.0, -1.0, 0.0));
        Material m = Material(MATERIAL_TYPE_OPAQUE, vec3(1.0, 0.0, 0.0), 0.0, 0.0);
        hit = u_op(hit, Hit(d, m, WORLD_SUB_LAVALAMP));
    }

    // blob and blubs
    {
        vec3 q = p;

        float y = world_height/2.0 + world_height * 0.7 * sin(2.0*PI*N(u.t_start) + u.t * 0.6);
        y = 5.0 + y*0.65;

        vec3 q_blob = q - vec3(0.0, y, 0.0);
        float r_blob = 3.5;
        float d = sd_sphere(q_blob, r_blob);
        d = smin(d, hit.d, 0.5);

        for (int i = 0; i < BLUBS; i++) {
            vec3 q_blub = q - g_blub_pos[i];
            float r = g_blub_r[i];
            float d2 = sd_sphere(q_blub, r);
            d = smin(d, d2, 1.5-0.8*r/5.0);
        }

        vec3 color = palette(p.y/world_height + 0.1 * u.t, vec3(0.5), vec3(0.5), vec3(1.0), vec3(0.0, 0.33, 0.67));
        Material m = Material(MATERIAL_TYPE_OPAQUE, color, 0.2, 0.8);
        hit = u_op(hit, Hit(d, m, WORLD_SUB_LAVALAMP));
    }
    return hit;
}

Hit map_lavalamp_p(vec3 p) {
    Hit hit = map_lavalamp_s(p);
    {
        mat2x3 portal = get_portal(WORLD_SUB_LAVALAMP);
        vec3 portal_pos = portal[0];
        vec3 portal_n = -portal[1];

        vec3 q = p - portal_pos;
        float d = sd_portal(q, portal_n);
        Material m = Material(MATERIAL_TYPE_PORTAL, vec3(1.0), 0.0, 0.0);
        hit = u_op(hit, Hit(d, m, WORLD_HUB));
    }
    return hit;
}

Hit map_mountains_s(vec3 p) {
    Hit hit;
    hit.world_target = NULL;

    float amp = 100.0;

    p.y += 0.3*amp;
    {
        vec3 q = p;
        vec2 offset = N12(u.t_start);
        float h = fbm(offset + q.xz * 0.02, 7);

        h *= amp;

        float w = 0.0;
        {
            float w_speed = u.t;
            float w_freq = 0.2*q.x;
            float w_amp = 4.0;
            for (int i = 0; i < 1; i++) {
                w += w_amp*-abs(sin(w_speed+w_freq));
                // w_speed *= 1.5;
                w_freq *= 1.5;
                w_amp *= 0.3;
            }
        }

        h = max(w, h);
        hit.d = p.y - h;
        hit.d *= 0.1;

        hit.material = Material(MATERIAL_TYPE_OPAQUE, vec3(0.0, 0.0, 1.0), 0.9, 0.2);
    }
    return hit;
}

Hit map_mountains_p(vec3 p) {
    Hit hit = map_mountains_s(p);
    {
        mat2x3 portal = get_portal(WORLD_SUB_MOUNTAINS);
        vec3 portal_pos = portal[0]; //TODO: pos
        vec3 portal_n = -portal[1];

        vec3 q = p - portal_pos;
        float d = sd_portal(q, portal_n);
        Material m = Material(MATERIAL_TYPE_PORTAL, vec3(1.0), 0.0, 0.0);
        hit = u_op(hit, Hit(d, m, WORLD_HUB));
    }
    return hit;
}

// map for secondary (and primary) rays
Hit map_secondary(vec3 p) {
    if (world_ray == WORLD_HUB) return map_hub_s(p);
    else if (world_ray == WORLD_SUB_FRACTAL) return map_fractal_s(p);
    else if (world_ray == WORLD_SUB_LAVALAMP) return map_lavalamp_s(p);
    else if (world_ray == WORLD_SUB_MOUNTAINS) return map_mountains_s(p);
    else return NULL_HIT;
}

// map for primary rays
Hit map_primary(vec3 p) {
    if (world_ray == WORLD_HUB) return map_hub_p(p);
    else if (world_ray == WORLD_SUB_FRACTAL) return map_fractal_p(p);
    else if (world_ray == WORLD_SUB_LAVALAMP) return map_lavalamp_p(p);
    else if (world_ray == WORLD_SUB_MOUNTAINS) return map_mountains_p(p);
    else return NULL_HIT;
}

////////////
// engine //
////////////

// TODO: change d to t
Hit march(vec3 ro, vec3 rd) {
    float d = 0.0;
    Hit hit;
    float r_prev = 0.0;
    float omega = 1.4;
    float step = 0.0;

    float d_candidate = 0.0;
    float error_candidate = 1e8;
    Material material_candidate = Material(MATERIAL_TYPE_OPAQUE, vec3(0.0), 0.0, 0.0);
    int target_candidate = NULL;

    float r_pixel = 1.0/u.resolution.y;

    float is = 0.0;
    for (int i = 0; i < STEPS_MAX; i++) {
        vec3 p = ro + d * rd;
        hit = map_primary(p);
        is++;

        float r = hit.d;

        float threshold = 0.001 + (d * 0.0002);
        if (abs(r) < threshold && hit.material.type == MATERIAL_TYPE_PORTAL) {
            world_ray = hit.world_target;
            vec3 n = get_portal(world_ray)[1];
            float a = abs(dot(n, rd));
            a = max(a, 1e-8);
            d += (20.0*threshold) / a;

            r_prev = 0.0;
            step = 0.0;
            error_candidate = 1e8;
            continue;
        }

        bool overstep = (omega > 1.0) && (r + r_prev) < step; // step from previous iteration
        if (overstep) {
            d -= step;
            step = r_prev;
            omega = 1.0;
            continue;
        }
        else {
            step = r * omega;
            r_prev = r;
        }

        float error = r / d;

        if (!overstep && error < error_candidate) {
            d_candidate = d;
            error_candidate = error;
            material_candidate = hit.material;
            target_candidate = hit.world_target;
        }

        if (!overstep && error < r_pixel && hit.material.type != MATERIAL_TYPE_PORTAL) break;
        if (r < threshold) break;

        if (d > D_MAX) return Hit(1e8, material_candidate, NULL);

        d += step;
    }

#ifdef DEBUG
    return Hit(is, material_candidate, target_candidate);
#endif

    if (error_candidate > r_pixel * 1.5) {
        return Hit(1e8, material_candidate, NULL);
    }

    return Hit(d_candidate, material_candidate, target_candidate);
}

vec3 normal(vec3 p) {
    vec2 e = vec2(1.0, -1.0) * 0.0001;
    return normalize(
            e.xyy * map_secondary(p + e.xyy).d +
            e.yyx * map_secondary(p + e.yyx).d +
            e.yxy * map_secondary(p + e.yxy).d +
            e.xxx * map_secondary(p + e.xxx).d
            );
}

float shadow(vec3 ro, vec3 rd, float d_max) {
    float d = 0.1;
    float occlusion = 1.0;
    for (int i = 0; i < 256 && d < d_max; i++) {
        vec3 p = ro + rd * d;
        float h = map_secondary(p).d;
        if (h < 0.001) return 0.0;
        occlusion = min(occlusion, 64.0*h/d);
        d += h;
    }
    return occlusion;
}

float ambient_occlusion(vec3 p, vec3 n) {
    float scale = 1.00;
    float occlusion = 0.0;
    for (int i = 1; i <= 4; i++) {
        float h = 0.04*float(i);
        float d = map_secondary(p + h*n).d;
        occlusion += (h-d) * scale;
        scale *= 0.95;
    }
    return 1.0 - clamp(occlusion, 0.0, 1.0);
}

// cook torrance pbr

// Trowbridge-Reitz GGX Normal Distribution
float distribution(vec3 n, vec3 h, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;

    float nh = max(dot(n, h), 0.0);
    float nh2 = nh * nh;

    float num = a2;
    float denom = (nh2 * (a2 - 1.0) + 1.0);
    denom = PI * denom * denom;

    return num / denom;
}

// Fresnel Schlick's approximation
vec3 fresnel(vec3 v, vec3 h, vec3 f0) {
    float cos_theta = max(dot(v,h), 0.0);
    return f0 + (1.0 - f0) * pow(clamp(1.0 - cos_theta, 0.0, 1.0), 5.0);
}

// Schlick-GGX
// calculates microfacet occlusion
float g1(vec3 n, vec3 dir, float roughness) {

    // remap roughness for direct lightning
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;

    float cos_theta = max(dot(n, dir), 0.0);

    float num = cos_theta;
    float denom = cos_theta * (1.0 - k) + k;

    return num / denom;
}

float geometry(vec3 n, vec3 v, vec3 l, float roughness) {
    // smith method
    float masking = g1(n, v, roughness);
    float shadowing = g1(n, l, roughness);

    return masking * shadowing;
}

vec3 lighting(vec3 p, vec3 n, vec3 v, Light light, Material material) {
    vec3 l = normalize(light.pos - p);
    vec3 h = normalize(v + l);

    vec3 f0 = vec3(0.04);
    f0 = mix(f0, material.albedo, material.metallic);

    float distance = length(light.pos - p);
    float attenuation = 1.0 / (distance * distance); // light follows inverse square law
    vec3 radiance = light.color * light.strength * attenuation;

    float D = distribution(n, h, material.roughness);
    float G = geometry(n, v, l, material.roughness);
    vec3 F = fresnel(v, h, f0);

    vec3 num = D * G * F;
    float denom = 4.0 * max(dot(n, v), 0.0) * max(dot(n, l), 0.0) + 0.0001;
    vec3 specular = num / denom;

    vec3 k_s = F;
    vec3 k_d = vec3(1.0) - k_s;

    k_d *= 1.0 - material.metallic;

    vec3 brdf = k_d * material.albedo / PI + specular;

    return brdf * radiance * max(dot(n, l), 0.0);
}

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;

    if (x >= u.resolution.x || y >= u.resolution.y) return;

    vec2 uv = vec2(float(x) / u.resolution.x, float(y) / u.resolution.y);
    uv = uv * 2.0 - 1.0;
    uv.y *= -1;
    uv.x *= u.resolution.x/u.resolution.y;

    vec3 ro = u.camera.pos;
    mat3 camera_orientation = mat3(u.camera.right, u.camera.up, u.camera.forward);
    vec3 rd = camera_orientation * normalize(vec3(uv, 1.0));

    int world = get_world();
    if (x == 0 && y == 0) {
        world_global = world;
        world_ray = world;
    }
    else world_ray = world;

    precalculate_blobs();

    Hit hit = march(ro, rd);

#ifdef DEBUG
    vec3 color = vec3(hit.d/STEPS_MAX);
#else
    vec3 color_bg = get_bg(world_ray);
    vec3 color = color_bg;

    if (hit.d < D_MAX) {
        vec3 p = ro + hit.d * rd;
        vec3 n = normal(p);
        vec3 v = normalize(ro - p);

        vec3 light_pos = u.camera.pos;
        vec3 light_color = vec3(1.0, 1.0, 1.0);
        Light lamp = Light(light_pos, light_color, 1500.0);
        vec3 direct = lighting(p, n, v, lamp, hit.material);

        vec3 l = normalize(light_pos - p);
        float s = shadow(p, l, length(light_pos - p));
        direct *= s;

        float ao = ambient_occlusion(p, n);
        vec3 ambient = vec3(0.0001) * hit.material.albedo * ao;

        color = direct + ambient;
    }

    float fog_factor = smoothstep(D_MAX * 0.9, D_MAX, hit.d);
    color = mix(color, color_bg, fog_factor);

    color = pow(color, vec3(1.0 / 2.2)); // gamma correction

    // dithering to reduce color banding
    float noise = N21(uv + u.t) * 2.0 - 1.0;
    color += noise * (1.0 / 255.0);
#endif
    imageStore(rendertarget, ivec2(x, y), vec4(color, 1.0));
}
