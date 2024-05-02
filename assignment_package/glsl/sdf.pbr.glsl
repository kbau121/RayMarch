// Schlick's fresnel approximation accounting for roughness
vec3 fresnelRoughness(float cosViewAngle, vec3 R, float roughness)
{
    return R + (max(vec3(1.f - roughness), R) - R) * pow(max(1.f - cosViewAngle, 0.f), 5.f);
}

vec3 metallic_plastic_LTE(BSDF bsdf, vec3 wo) {
    vec3 N = bsdf.nor;
    vec3 albedo = bsdf.albedo;
    float metallic = bsdf.metallic;
    float roughness = bsdf.roughness;
    float ambientOcclusion = bsdf.ao;

    vec3 R = mix(vec3(0.04f), albedo, metallic);
    vec3 F = fresnelRoughness(max(dot(N, wo), 0.f), R, roughness);

    // Cook-Torrence weights
    vec3 ks = F;
    vec3 kd = 1.f - ks;
    kd *= 1.f - metallic;

    // Diffuse color
    vec3 diffuseIrradiance = texture(u_DiffuseIrradianceMap, N).rgb;
    vec3 diffuse = albedo * diffuseIrradiance;

    // Sample the glossy irradiance map
    vec3 wi = reflect(-wo, N);
    const float MAX_REFLECTION_LOD = 4.f;
    vec3 prefilteredColor = textureLod(u_GlossyIrradianceMap, wi, roughness * MAX_REFLECTION_LOD).rgb;

    // Specular color
    vec2 envBRDF = texture(u_BRDFLookupTexture, vec2(max(dot(N, wo), 0.f), roughness)).rg;
    vec3 specular = prefilteredColor * (F * envBRDF.x + envBRDF.y);

    // Ambient color
    vec3 ambient = 0.03f * albedo * ambientOcclusion;

    // Cook-Torrence lighting
    return ambient + kd * diffuse + specular;
}
