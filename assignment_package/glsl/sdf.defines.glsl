#version 330 core

uniform float u_Time;

uniform vec3 u_CamPos;
uniform vec3 u_Forward, u_Right, u_Up;
uniform vec2 u_ScreenDims;

// PBR material attributes
uniform vec3 u_Albedo;
uniform float u_Metallic;
uniform float u_Roughness;
uniform float u_AmbientOcclusion;
// Texture maps for controlling some of the attribs above, plus normal mapping
uniform sampler2D u_AlbedoMap;
uniform sampler2D u_MetallicMap;
uniform sampler2D u_RoughnessMap;
uniform sampler2D u_AOMap;
uniform sampler2D u_NormalMap;
// If true, use the textures listed above instead of the GUI slider values
uniform bool u_UseAlbedoMap;
uniform bool u_UseMetallicMap;
uniform bool u_UseRoughnessMap;
uniform bool u_UseAOMap;
uniform bool u_UseNormalMap;

// Image-based lighting
uniform samplerCube u_DiffuseIrradianceMap;
uniform samplerCube u_GlossyIrradianceMap;
uniform sampler2D u_BRDFLookupTexture;

// Varyings
in vec2 fs_UV;
out vec4 out_Col;

const float PI = 3.14159f;

struct Ray {
    vec3 origin;
    vec3 direction;
};

struct BSDF {
    vec3 pos;
    vec3 nor;
    vec3 albedo;
    float metallic;
    float roughness;
    float ao;
    float thinness;
};

struct MarchResult {
    float t;
    int hitSomething;
    BSDF bsdf;
};

struct SmoothMinResult {
    float dist;
    float material_t;
};

float dot2( in vec2 v ) { return dot(v,v); }
float dot2( in vec3 v ) { return dot(v,v); }
float ndot( in vec2 a, in vec2 b ) { return a.x*b.x - a.y*b.y; }

float sceneSDF(vec3 query);

vec3 SDF_Normal(vec3 query) {
    vec2 epsilon = vec2(0.0, 0.001);
    return normalize( vec3( sceneSDF(query + epsilon.yxx) - sceneSDF(query - epsilon.yxx),
                            sceneSDF(query + epsilon.xyx) - sceneSDF(query - epsilon.xyx),
                            sceneSDF(query + epsilon.xxy) - sceneSDF(query - epsilon.xxy)));
}

float SDF_Sphere(vec3 query, vec3 center, float radius) {
    return length(query - center) - radius;
}

float SDF_Box(vec3 query, vec3 bounds ) {
  vec3 q = abs(query) - bounds;
  return length(max(q,0.0)) + min(max(q.x,max(q.y,q.z)),0.0);
}

float SDF_RoundCone( vec3 query, vec3 a, vec3 b, float r1, float r2) {
  // sampling independent computations (only depend on shape)
  vec3  ba = b - a;
  float l2 = dot(ba,ba);
  float rr = r1 - r2;
  float a2 = l2 - rr*rr;
  float il2 = 1.0/l2;

  // sampling dependant computations
  vec3 pa = query - a;
  float y = dot(pa,ba);
  float z = y - l2;
  float x2 = dot2( pa*l2 - ba*y );
  float y2 = y*y*l2;
  float z2 = z*z*l2;

  // single square root!
  float k = sign(rr)*rr*rr*x2;
  if( sign(z)*a2*z2>k ) return  sqrt(x2 + z2)        *il2 - r2;
  if( sign(y)*a2*y2<k ) return  sqrt(x2 + y2)        *il2 - r1;
                        return (sqrt(x2*a2*il2)+y*rr)*il2 - r1;
}

float SDF_Torus(vec3 query, vec2 t)
{
    vec2 q = vec2(length(query.xz) - t.x, query.y);
    return length(q) - t.y;
}

float SDF_CappedTorus(vec3 query, vec2 sc, float ra, float rb)
{
    query.x = abs(query.x);
    float k = (sc.y * query.x > sc.x * query.y) ? dot(query.xy, sc) : length(query.xy);
    return sqrt(dot2(query) + ra * ra - 2.f * ra * k) - rb;
}

float SDF_Ellipsoid(vec3 query, vec3 r)
{
    float k0 = length(query / r);
    float k1 = length(query / (r * r));
    return k0 * (k0 - 1.f) / k1;
}

float smooth_min( float a, float b, float k ) {
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

SmoothMinResult smooth_min_lerp( float a, float b, float k ) {
    float h = max( k-abs(a-b), 0.0 )/k;
    float m = h*h*0.5;
    float s = m*k*0.5;
    if(a < b) {
        return SmoothMinResult(a-s,m);
    }
    return SmoothMinResult(b-s,1.0-m);
}
vec3 repeat(vec3 query, vec3 cell) {
    return mod(query + 0.5 * cell, cell) - 0.5 * cell;
}

float subtract(float d1, float d2) {
    return max(d1, -d2);
}

float opIntersection( float d1, float d2 ) {
    return max(d1,d2);
}

float opSmoothIntersection(float d1, float d2, float k)
{
    float h = clamp(0.5f - 0.5f * (d2 - d1) / k, 0.f, 1.f);
    return mix(d2, d1, h) + k * h * (1.f - h);
}

float opSmoothUnion(float d1, float d2, float k)
{
    float h = clamp(0.5f + 0.5f * (d2 - d1) / k, 0.f, 1.f);
    return mix(d2, d1, h) - k * h * (1.f - h);
}

float opOnion(float sdf, float thickness ) {
    return abs(sdf)-thickness;
}

vec3 rotateX(vec3 p, float angle) {
    angle = angle * 3.14159 / 180.f;
    float c = cos(angle);
    float s = sin(angle);
    return vec3(p.x, c * p.y - s * p.z, s * p.y + c * p.z);
}

vec3 rotateY(vec3 p, float angle)
{
    angle = angle * 3.14159 / 180.f;
    float c = cos(angle);
    float s = sin(angle);
    return vec3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
}

vec3 rotateZ(vec3 p, float angle) {
    angle = angle * 3.14159 / 180.f;
    float c = cos(angle);
    float s = sin(angle);
    return vec3(c * p.x - s * p.y, s * p.x + c * p.y, p.z);
}

float SDF_Stache(vec3 query) {
    float left = SDF_Sphere(query / vec3(1,1,0.3), vec3(0.2, -0.435, 3.5), 0.1) * 0.1;
    left = min(left, SDF_Sphere(query / vec3(1,1,0.3), vec3(0.45, -0.355, 3.5), 0.1) * 0.1);
    left = min(left, SDF_Sphere(query / vec3(1,1,0.3), vec3(0.7, -0.235, 3.5), 0.09) * 0.1);
    left = subtract(left, SDF_Sphere(rotateZ(query, -15) / vec3(1.3,1,1), vec3(0.3, -0.1, 1.), 0.35));

    float right = SDF_Sphere(query / vec3(1,1,0.3), vec3(-0.2, -0.435, 3.5), 0.1) * 0.1;
    right = min(right, SDF_Sphere(query / vec3(1,1,0.3), vec3(-0.45, -0.355, 3.5), 0.1) * 0.1);
    right = min(right, SDF_Sphere(query / vec3(1,1,0.3), vec3(-0.7, -0.235, 3.5), 0.09) * 0.1);
    right = subtract(right, SDF_Sphere(rotateZ(query, 15) / vec3(1.3,1,1), vec3(-0.3, -0.1, 1.), 0.35));

    return min(left, right);
}

float SDF_Wahoo_Skin(vec3 query) {
    // head base
    float result = SDF_Sphere(query / vec3(1,1.2,1), vec3(0,0,0), 1.) * 1.1;
    // cheek L
    result = smooth_min(result, SDF_Sphere(query, vec3(0.5, -0.4, 0.5), 0.5), 0.3);
    // cheek R
    result = smooth_min(result, SDF_Sphere(query, vec3(-0.5, -0.4, 0.5), 0.5), 0.3);
    // chin
    result = smooth_min(result, SDF_Sphere(query, vec3(0.0, -0.85, 0.5), 0.35), 0.3);
    // nose
    result = smooth_min(result, SDF_Sphere(query / vec3(1.15,1,1), vec3(0, -0.2, 1.15), 0.35), 0.05);
    return result;
}

float SDF_Wahoo_Hat(vec3 query) {
    float result = SDF_Sphere(rotateX(query, 20) / vec3(1.1,0.5,1), vec3(0,1.65,0.4), 1.);
    result = smooth_min(result, SDF_Sphere((query - vec3(0,0.7,-0.95)) / vec3(2.5, 1.2, 1), vec3(0,0,0), 0.2), 0.3);
    result = smooth_min(result, SDF_Sphere(query / vec3(1.5,1,1), vec3(0, 1.3, 0.65), 0.5), 0.3);

    float brim = opOnion(SDF_Sphere(query / vec3(1.02, 1, 1), vec3(0, -0.15, 1.), 1.1), 0.02);

    brim = subtract(brim, SDF_Box(rotateX(query - vec3(0, -0.55, 0), 10), vec3(10, 1, 10)));

    result = min(result, brim);

    return result;
}


float SDF_Wahoo(vec3 query) {
    // Flesh-colored parts
    float result = SDF_Wahoo_Skin(query);
    // 'stache parts
    result = min(result, SDF_Stache(query));
    // hat
    result = min(result, SDF_Wahoo_Hat(query));

    return result;
}

BSDF BSDF_Wahoo(vec3 query) {
    // Head base
    BSDF result = BSDF(query, normalize(query), pow(vec3(239, 181, 148) / 255., vec3(2.2)),
                       0., 0.7, 1., 0.);

    result.nor = SDF_Normal(query);

    float skin = SDF_Wahoo_Skin(query);
    float stache = SDF_Stache(query);
    float hat = SDF_Wahoo_Hat(query);

    if(stache < skin && stache < hat) {
        result.albedo = pow(vec3(68,30,16) / 255., vec3(2.2));
    }
    if(hat < skin && hat < stache) {
        result.albedo = pow(vec3(186,45,41) / 255., vec3(2.2));
    }

    return result;
}

#define SEARCH_DISTANCE 0.085f
float ambientOcclusion(vec3 pos, vec3 nor, float thinness)
{
    float ambientOcclusion = 0.f;
    for (int i = 1; i <= 5; ++i)
    {
        float distance = max(0.f, -sceneSDF(pos + nor * i * SEARCH_DISTANCE));
        ambientOcclusion += (i * SEARCH_DISTANCE - distance) / pow(2, i);
    }

    return clamp(1.f - thinness * ambientOcclusion, 0.f, 1.f);
}

#define DISTORTION 0.2f
#define GLOW 6.f
#define SCALE 3.f
vec3 subsurfaceAttenuation(vec3 albedo, float ambient, vec3 lightDir, vec3 normal, vec3 viewVec, float thinness)
{
    vec3 scatterDir = lightDir + normal * DISTORTION;
    float lightReachingEye = pow(clamp(dot(viewVec, -scatterDir), 0.f, 1.f), GLOW) * SCALE;
    float attenuation = max(0.f, dot(normal, lightDir) + dot(viewVec, -lightDir));
    float totalLight = attenuation * (lightReachingEye + ambient) * thinness;
    return albedo * totalLight;
}

// https://www.shadertoy.com/view/3llfRl
vec2 bend(vec2 p, vec2 c, float k)
{
    p -= c;
    float ang = atan(p.x, p.y);
    float len = length(p);
    ang -= ang / sqrt(1.f + ang * ang) * (1.f - k);
    return vec2(sin(ang), cos(ang)) * len + c;
}

float SDF_Head_Base(vec3 query)
{
    float headTop = SDF_Sphere(query, vec3(0.f, 1.f, 0.f), 1.2f);
    float headBottom = opSmoothIntersection(
                SDF_Box(query, vec3(0.5f, 0.2f, 0.5f)),
                SDF_Sphere(query, vec3(0.f, 0.f, 0.f), 0.5f),
                0.1f);
    return opSmoothUnion(headTop, headBottom, 1.f);
}

float SDF_Head_Smile(vec3 query)
{
    float smileAngle = 80.f * PI / 180.f;
    return SDF_CappedTorus(
                rotateX(rotateZ(query - vec3(0.f, 0.8f, 1.18f), 180.f), 7.5f),
                vec2(sin(smileAngle), cos(smileAngle)),
                0.25f, 0.02f);
}

float SDF_Head_Eyes(vec3 query)
{
    return SDF_Sphere(vec3(abs(query.x), query.yz), vec3(0.5f, 1.05f, 0.97f), 0.15f);
}

float SDF_Head_Eyebrows(vec3 query)
{
    float eyebrowScale = 0.19f;
    vec3 eyebrowQuery = vec3(abs(query.x), query.yz) - vec3(0.53f, 1.3f, 0.98f);
    return opSmoothIntersection(
                SDF_Box(eyebrowQuery / eyebrowScale, vec3(0.5f, 0.2f, 0.5f)),
                SDF_Sphere(eyebrowQuery / eyebrowScale, vec3(0.f, 0.f, 0.f), 0.4f),
                0.1f) * eyebrowScale;
}

float SDF_Head(vec3 query)
{
    float result;

    // Base
    result = SDF_Head_Base(query);

    // Face
    // Smile
    result = min(result, SDF_Head_Smile(query));
    // Eyes
    result = min(result, SDF_Head_Eyes(query));
    // Eyebrows
    result = min(result, SDF_Head_Eyebrows(query));

    return result;
}

float SDF_Tentacle_Bottom_CutOut(vec3 query)
{
    // Parameters
    const float length = 2.f;
    const float rA = 0.9f;
    const float rB = 0.3f;
    const float falloff = 0.05f;
    const float maxR = max(rA, rB);

    return SDF_Box(query - vec3(length / 2.f, -(maxR - falloff), 0.f), vec3(length, maxR, maxR * 2.f));
}

float SDF_Tentacle(vec3 query)
{
    vec3 q = query;

    // Transform
    q = rotateZ(q, -135.f);

    // Parameters
    const float length = 2.f;
    const float rA = 0.9f;
    const float rB = 0.3f;
    const float falloff = 0.05f;
    const float maxR = max(rA, rB);

    // Bend
    q.xy = bend(q.xy, vec2(length, -1.5f), 0.5f);
    q.xy = bend(q.xy, vec2(0.6f * length, -1.5f), 0.f);

    // Shape
    float result = SDF_RoundCone(q, vec3(0.f, 0.f, 0.f), vec3(length, 0.f, 0.f), rA, rB);
    result = opSmoothIntersection(result, SDF_Tentacle_Bottom_CutOut(q), 0.1f);

    return result;
}

float SDF_Cups(vec3 query)
{
    float result;
    query = vec3(abs(query.x), query.yz);
    vec3 cupQuery;

    const float rA = 0.03f;
    const float rB = 0.015f;

    cupQuery = query - vec3(0.f, -0.3f, 2.08f);
    result = SDF_Torus(rotateX(cupQuery, 100.f), vec2(rA, rB));

    cupQuery = query - vec3(0.055f, -0.5f, 2.09f);
    result = min(result, SDF_Torus(rotateX(cupQuery, 85.f), vec2(rA, rB)));

    cupQuery = query - vec3(0.075f, -0.7f, 2.01f);
    result = min(result, SDF_Torus(rotateX(cupQuery, 53.f), vec2(rA, rB)));

    cupQuery = query - vec3(0.085f, -0.85f, 1.8f);
    result = min(result, SDF_Torus(rotateX(cupQuery, 22.f), vec2(rA, rB)));

    cupQuery = query - vec3(0.085f, -0.885f, 1.5f);
    result = min(result, SDF_Torus(rotateX(cupQuery, -10.f), vec2(rA, rB)));

    return result;
}

float SDF_Octopus(vec3 query)
{
    float result;

    // Head
    float headScale = 1.2f;
    result = SDF_Head(query / headScale) * headScale;

    // Tentacles
    float tentacleScale = 0.3f;
    float tentacleAngle = 45.f / 2.f;
    vec3 tentacleTrans = vec3(-1.7f, -0.5f, 0.f);

    float tentacles = 1.f / 0.f;
    for (int i = 0; i < 2; ++i)
    {
        vec3 tentacleQuery = vec3(-abs(query.x), query.y, -abs(query.z));
        tentacleQuery = rotateY(tentacleQuery, 45.f * i + tentacleAngle);
        tentacleQuery = rotateZ(tentacleQuery, -20.f);
        tentacleQuery -= tentacleTrans;

        tentacles = min(tentacles, SDF_Tentacle(tentacleQuery / tentacleScale) * tentacleScale);
    }
    result = smooth_min(result, tentacles, 0.3f);

    // Cups
    for (int i = 0; i < 2; ++i)
    {
        vec3 cupsQuery = vec3(-abs(query.x), query.y, abs(query.z));
        cupsQuery = rotateY(cupsQuery, 45.f * i + tentacleAngle);
        result = min(result, SDF_Cups(cupsQuery));
    }

    return result;
}

float sceneSDF(vec3 query) {

    //return SDF_Sphere(query, vec3(0.), 1.f);
    //return SDF_Wahoo(query);
    return SDF_Octopus(query);
}


BSDF sceneBSDF(vec3 query) {

    return BSDF(query, SDF_Normal(query), vec3(1.f), 0.f, 0.9f, 0.f, 2.f);
    //return BSDF_Wahoo(query);
}
