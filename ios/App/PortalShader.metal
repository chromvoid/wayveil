// Ported from the approved C2 button preview in docs/brand/portal-shader-concept.html.
#include <metal_stdlib>
using namespace metal;

// Matches PortalEffect.Uniforms: 192 bytes, tilt at 32, logoRect at 48, press at 68, packets at 80, light at 176.
struct PortalUniforms {
    float2 resolution;
    float scale;
    float time;
    float power;
    float busy;
    // close runs 0..1 after the tunnel goes dark (1 when idle); impact counts seconds since it connected.
    float close;
    float impact;
    // x > 0 when the right edge turns away from the viewer, y > 0 when the top edge does.
    float2 tilt;
    // The two logo crescents part along the glyph's x axis by split, turn together by spin, and smear by spinBlur.
    float split;
    float spin;
    float4 logoRect;
    float spinBlur;
    // Eases to 1 while a finger is down on the button.
    float press;
    // The traffic packets, placed by PortalTraffic: the unit vector to each head, and in z how fast its tail fades.
    // The first three run along the inner wire.
    float4 packets[6];
    // The portal's one light, placed by PortalLight: the unit vector towards it (x right, y up, z towards the viewer),
    // and in w how far tilt has drawn it down.
    float4 light;
};

struct PortalVertex {
    float4 position [[position]];
};

vertex PortalVertex portalVertex(uint index [[vertex_id]]) {
    const float2 positions[] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
    return {float4(positions[index], 0, 1)};
}

constant float PI = 3.14159265;
constexpr sampler logoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
constexpr sampler latticeSampler(coord::normalized, address::repeat, filter::linear);
float hash(float2 p) {
  p = fract(p * float2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}
// The lattice texture holds value-noise hashes at its texel centres (see PortalEffect.Renderer), so linear filtering does the mixing.
float noise(texture2d<float> lattice, float2 p) {
  float2 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return lattice.sample(latticeSampler, (i + f + 0.5) / 256.0).r;
}
float fbm(texture2d<float> lattice, float2 p) {
  float f = 0.0, amplitude = 0.5;
  for (int i = 0; i < 4; i++) {
    f += amplitude * noise(lattice, p);
    p = float2x2(1.6, 1.2, -1.2, 1.6) * p + 3.1;
    amplitude *= 0.5;
  }
  return f;
}
float band(float d, float width) { return exp(-d * d / (width * width)); }
float2 turn(float2 v, float a) {
  float c = cos(a), s = sin(a);
  return float2(c * v.x - s * v.y, s * v.x + c * v.y);
}
// Each crescent of the C2 glyph lies wholly on one side of its vertical axis.
float logoHalf(texture2d<float> logoMask, float2 glyph, float side, float spin, float gap) {
  float2 q = turn(glyph, -spin) - float2(side * gap, 0.0);
  if (side * q.x < 0.0 || abs(q.x) > 1.0 || abs(q.y) > 1.0) return 0.0;
  return logoMask.sample(logoSampler, float2(0.5 + 0.5 * q.x, 0.5 - 0.5 * q.y)).a;
}
float logoHalves(texture2d<float> logoMask, float2 glyph, float spin, float gap) {
  return logoHalf(logoMask, glyph, 1.0, spin, gap) + logoHalf(logoMask, glyph, -1.0, spin, gap);
}
float logoCover(texture2d<float> logoMask, float2 glyph, float spin, float blur, float gap) {
  if (blur == 0.0) return min(logoHalves(logoMask, glyph, spin, gap), 1.0);
  float mask = 0.0;
  for (int i = -1; i <= 1; i++) {
    mask += (i == 0 ? 0.5 : 0.25) * logoHalves(logoMask, glyph, spin + float(i) * blur, gap);
  }
  return min(mask, 1.0);
}
fragment half4 portalFragment(PortalVertex input [[stage_in]], constant PortalUniforms &uniforms [[buffer(0)]],
                              texture2d<float> logoMask [[texture(0)]], texture2d<float> lattice [[texture(1)]]) {
    float2 position = input.position.xy;
    float2 uResolution = uniforms.resolution;
    float uScale = uniforms.scale;
    float uTime = uniforms.time;
    float uPower = uniforms.power;
    float uBusy = uniforms.busy;
    float uClose = uniforms.close;
    float uImpact = uniforms.impact;
    float2 uTilt = uniforms.tilt;
    float uSplit = uniforms.split;
    float uSpin = uniforms.spin;
    float uSpinBlur = uniforms.spinBlur;
    float uPress = uniforms.press;
    float4 uLogoRect = uniforms.logoRect;
    float4 uLight = uniforms.light;
  float2 rawPosition = (2.0 * float2(position.x, uResolution.y - position.y) - uResolution) / min(uResolution.x, uResolution.y);
  float opacity = 1.0 - smoothstep(0.88, 1.0, length(rawPosition));
  if (opacity <= 0.0) return half4(0.0);
  float2 p = rawPosition * uScale;
  float t = uTime;
  float2 logoCenter = uLogoRect.xy + uLogoRect.zw * 0.5;
  float2 logoP = (2.0 * float2(logoCenter.x, uResolution.y - logoCenter.y) - uResolution)
    / min(uResolution.x, uResolution.y) * uScale;
  // The ring and the logo's shadow lie on a plane behind the logo, so tilting slides that plane one way and the logo
  // the other. From here on p and logoP are coordinates in the ring's plane.
  p += uTilt * 0.018;
  logoP += uTilt * 0.039;
  // The portal's one light, placed by PortalLight: it circles slowly and leans towards the edge that turned to the viewer.
  float3 light = uLight.xyz;
  float lean = uLight.w;
  float lightSpread = length(light.xy);
  float2 lightDir = light.xy / max(lightSpread, 0.0001);
  // Light from straight ahead lights the ring evenly, so its highlights gather on one side only as it leans.
  float aim = smoothstep(0.0, 0.25, lightSpread);

  // Connect impact: a pressure front leaves the locking logo, lenses the scene and then hits the ring.
  float impacting = uImpact < 2.0 ? 1.0 : 0.0;
  float impact = max(uImpact - 0.08, 0.0);
  float shockRadius = 0.10 + 1.05 * (1.0 - exp(-impact * 2.4));
  float shockWidth = 0.03 + 0.06 * impact;
  float shockFade = exp(-impact * 2.2) * smoothstep(0.0, 0.03, uImpact) * impacting;
  // The front is born at the logo and recentres on the ring by the time it reaches it.
  float2 shockP = p - logoP * (1.0 - smoothstep(0.0, 0.3, impact));
  float shockR = length(shockP);
  float front = 0.0;
  if (impacting > 0.0) {
    float shockDistance = shockR - shockRadius;
    float lens = shockDistance / shockWidth * exp(-shockDistance * shockDistance / (shockWidth * shockWidth));
    p -= shockP / max(shockR, 0.0001) * lens * 0.022 * shockFade;
    front = band(shockDistance, 0.005 + 0.012 * impact);
  }
  float r = length(p);
  float hitAge = impact - 0.26;
  float hit = hitAge > 0.0 ? impacting : 0.0;
  float kick = hit * exp(-hitAge * 7.0) * sin(hitAge * 30.0);
  float surge = hit * exp(-hitAge * 3.5);

  float closeActive = uClose < 1.0 ? 1.0 : 0.0;
  float closing = uClose * closeActive;
  float squeeze = sin(PI * smoothstep(0.0, 0.7, closing)) * closeActive;
  // A press squeezes the ring and lights it, so the whole portal answers the finger.
  float energy = 0.19 + uPower * 0.71 + uBusy * 0.65 + surge * 0.9 + uPress * 0.35;
  float radius = 0.588 - 0.06 * squeeze + 0.022 * kick - 0.014 * uPress;
  // ChromVoid's dark palette on hue 232: its accent, a near-white of the same hue and its decorative cyan.
  float3 cyan = float3(0.518, 0.835, 1.0);
  float3 ice = float3(0.875, 0.965, 1.0);
  float3 deep = float3(0.043, 0.624, 0.835);
  // Tiny leftovers of easing count as off, so the busy-only layers below can be skipped.
  float busy = uBusy > 0.001 ? uBusy : 0.0;
  // Connected and not closing: the steady state that carries traffic.
  float calm = uPower * (1.0 - busy) * (1.0 - smoothstep(0.0, 0.4, closing));
  float2 circle = p / max(r, 0.0001);
  float2 circle2 = float2(circle.x * circle.x - circle.y * circle.y, 2.0 * circle.x * circle.y);
  float2 circle3 = float2(circle2.x * circle.x - circle2.y * circle.y, circle2.x * circle.y + circle2.y * circle.x);
  float ringDistance = r - radius;
  // The flow noise only shapes the ring and its near glow, so far from it it rests at its mean.
  float flow = abs(ringDistance) < 0.2 ? fbm(lattice, circle * 3.4 + float2(t * 0.24, -t * 0.19)) : 0.5;
  float warp = (flow - 0.5) * (0.008 + 0.045 * uBusy) * (1.0 - smoothstep(0.14, 0.2, abs(ringDistance)));
  float d = ringDistance - warp;
  float3 bg = mix(float3(0.047, 0.094, 0.122), float3(0.053, 0.175, 0.232), exp(-r * r * 1.7) * 0.72);
  float grain = (hash(position) - 0.5) * 0.007;
  float3 col = bg + grain;
  col += deep * exp(-abs(d) * 11.0) * energy * 0.13;
  col += cyan * exp(-abs(d) * 33.0) * energy * 0.13;

  float material = 1.0 - smoothstep(0.028, 0.055, abs(d));
  float idle = 1.0 - clamp(uPower + uBusy, 0.0, 1.0);
  float detailEnergy = energy + idle * 0.29;
  // The metal, its filaments and the moving glint all vanish within 0.1 of the ring.
  if (abs(d) < 0.1) {
    // Connected traffic: packets of light run along the two wires, one stream each way, and wake the veins as they pass.
    float rush = 0.0;
    float3 packets = float3(0.0);
    if (calm > 0.0) {
      // A wire looks the same under each of its packets, so its profile is worked out once per pixel: x the inner wire, y the outer.
      float2 core = float2(band(d + 0.026, 0.0045), band(d - 0.028, 0.0045));
      float2 glow = float2(band(d + 0.026, 0.03), band(d - 0.028, 0.03));
      float2 comets = float2(0.0);
      for (int i = 0; i < 6; i++) {
        float4 packet = uniforms.packets[i];
        float dir = i < 3 ? 1.0 : -1.0;
        float2 toHead = packet.xy;
        // The chord to the head stands in for the angle, so no atan; its sign says which side of the head a point lies.
        float ahead = length(circle - toHead) * sign(dir * (toHead.x * circle.y - toHead.y * circle.x));
        float comet = ahead > 0.0 ? exp(-ahead * 40.0) : exp(ahead * packet.z) * (0.5 + 0.5 * dot(circle, toHead));
        if (i < 3) comets.x += comet; else comets.y += comet;
      }
      rush = dot(glow, comets) * calm;
      packets = ice * dot(core, comets) * 2.0 * calm + cyan * rush * 0.4;
    }
    // The metal mirrors the light in two broad lobes, one towards it and one opposite; the far one fades as the light leans.
    float2 lightDir2 = float2(lightDir.x * lightDir.x - lightDir.y * lightDir.y, 2.0 * lightDir.x * lightDir.y);
    float2 facing2 = float2(dot(circle2, lightDir2), lightDir2.x * circle2.y - lightDir2.y * circle2.x);
    float reflectionPhase = (flow - 0.5) * mix(0.35, 1.1, idle);
    float reflection = pow(clamp(0.5 + 0.5 * aim * (facing2.x * cos(reflectionPhase) - facing2.y * sin(reflectionPhase)), 0.0, 1.0), mix(2.5, 4.0, idle))
      * (1.0 - lean * (0.15 + 0.25 * (1.0 - dot(circle, lightDir))));
    float veinPhase = d * 120.0 + flow * 16.0 - t * 1.8;
    float vein = pow(clamp(0.5 + 0.5 * (circle3.y * cos(veinPhase) + circle3.x * sin(veinPhase)), 0.0, 1.0), 5.0);
    float3 metal = mix(float3(0.056, 0.143, 0.186), cyan, reflection * (0.86 - idle * 0.21 * (1.0 - vein)));
    metal += ice * vein * (0.32 * detailEnergy + 1.2 * rush);
    col = mix(col, metal * (0.66 + energy * 0.52), material);
    col += packets + cyan * material * rush * 0.3;

    float edgeFlow = fbm(lattice, circle * 6.0 + float2(t * 0.38, t * 0.2));
    float filament = band(d + 0.026 + 0.006 * edgeFlow, 0.0025);
    float inner = band(d - 0.028 + 0.004 * flow, 0.002);
    col += cyan * filament * detailEnergy * (0.5 + reflection);
    col += ice * inner * detailEnergy * (0.1 + 0.65 * edgeFlow);
    // The ring's crest faces 40 degrees outwards, so it catches the light on the side the light leans to.
    float glint = pow(max(0.0, 0.65 * dot(circle, light.xy) + 0.76 * light.z), 22.0);
    col += ice * band(d, 0.022) * glint * (0.24 + 0.26 * uPower);
  }
  // As tilt draws the light down to the edge that turned towards the viewer, it lights a hard highlight there.
  if (lean > 0.0 && abs(d) < 0.25) {
    float facing = clamp(dot(circle, lightDir), 0.0, 1.0) * aim;
    float spot = pow(facing, 18.0) * lean;
    col += ice * band(d, 0.016) * spot * 1.25;
    col += cyan * band(d, 0.06) * spot * 0.22;
    col += cyan * material * pow(facing, 3.0) * lean * 0.16;
  }

  if (busy > 0.0) {
    if (abs(d) < 0.2) {
      float tail = pow(clamp(0.5 + 0.5 * dot(circle, float2(cos(t * 2.7), sin(t * 2.7))), 0.0, 1.0), 9.0);
      col += ice * band(d, 0.008) * tail * busy * 1.5;
      col += cyan * band(d, 0.044) * tail * busy * 0.30;
    }
    if (r > 0.57 && abs(d - 0.055) < 0.5) {
      float haze = fbm(lattice, p * 4.8 + float2(t * 0.13, -t * 0.22));
      float curtainPhase = haze * 9.0 - t;
      float curtain = pow(max(0.0, 1.0 - abs(circle3.y * cos(curtainPhase) + circle3.x * sin(curtainPhase))), 5.0);
      float aura = exp(-abs(d - 0.055) * 13.0) * smoothstep(0.57, 0.69, r);
      col += mix(deep, cyan, haze) * curtain * aura * busy * 0.37;
    }
    // Sparks orbit between 0.07 and 0.26 outside the ring; their glow fades within 0.07.
    if (r > radius && r < radius + 0.34) {
      for (int i = 0; i < 18; i++) {
        float id = float(i);
        float seed = hash(float2(id, 4.0));
        float angle = id * 2.39996 + t * (0.24 + seed * 0.35);
        float orbit = radius + 0.07 + seed * 0.19;
        float2 point = float2(cos(angle), sin(angle)) * orbit;
        float dist = length(p - point);
        float twinkle = 0.4 + 0.6 * pow(0.5 + 0.5 * sin(t * 2.0 + id), 3.0);
        col += ice * exp(-dist * dist / 0.000024) * twinkle * busy * 1.2;
        col += cyan * exp(-dist * dist / 0.00050) * twinkle * busy * 0.11;
      }
    }
  }

  if (impacting > 0.0) {
    col += ice * front * shockFade * 1.1;
    col += cyan * band(shockR - shockRadius, shockWidth * 1.6) * shockFade * 0.28;
    float echo = max(impact - 0.14, 0.0);
    float echoRadius = 0.10 + 1.05 * (1.0 - exp(-echo * 2.4));
    float echoR = length(p - logoP * (1.0 - smoothstep(0.0, 0.3, echo)));
    col += cyan * band(echoR - echoRadius, 0.006 + 0.012 * echo) * exp(-echo * 2.6) * step(0.0, impact - 0.14) * 0.45;
  }
  // Closing: the ring's light drains inward across the portal and is swallowed by the logo.
  if (closeActive > 0.0) {
    float drain = smoothstep(0.04, 0.62, closing);
    float drainRadius = mix(radius, 0.06, drain);
    float drainR = length(p - logoP * drain);
    float drainFade = smoothstep(0.0, 0.08, closing) * (1.0 - smoothstep(0.55, 0.68, closing));
    col += ice * band(drainR - drainRadius, 0.010) * drainFade * 0.55;
    col += cyan * band(drainR - drainRadius, 0.045) * drainFade * 0.16;
  }
  if (uLogoRect.z > 0.0 && uLogoRect.w > 0.0) {
    float2 logoUV = (position - uLogoRect.xy) / uLogoRect.zw;
    float2 glyph = float2(logoUV.x * 2.0 - 1.0, 1.0 - logoUV.y * 2.0);
    float reach = dot(glyph, glyph);
    if (reach < 3.2) {
      // The logo floats in the portal: it slides with tilt over its shadow, which lies on the ring's plane and falls away
      // from the light, and it sinks a little under a press.
      glyph *= 1.0 + 0.06 * uPress;
      float2 slant = light.xy / light.z;
      float2 shadowGlyph = glyph + slant * 0.15 + uTilt * 0.11;
      float gap = uSplit * 0.17;
      float shadow = 0.5 * logoHalves(logoMask, shadowGlyph, uSpin, gap)
        + 0.25 * logoHalves(logoMask, shadowGlyph + slant * 0.06, uSpin, gap);
      col *= 1.0 - 0.3 * min(shadow, 1.0);
      glyph -= uTilt * 0.13;
      reach = dot(glyph, glyph);
      float2 spun = turn(glyph, -uSpin);
      float open = clamp(uSplit, 0.0, 1.0);
      // Light leaks through the crack between the parted crescents.
      float seamWidth = 0.03 + 0.11 * open;
      float crack = exp(-spun.x * spun.x / (seamWidth * seamWidth)) * (1.0 - smoothstep(0.35, 1.05, abs(spun.y)));
      if (open > 0.0) {
        float core = exp(-reach / (0.05 + 0.18 * open));
        float flicker = 0.7 + 0.3 * fbm(lattice, spun * 3.0 + float2(t * 1.7, -t * 1.3));
        float leak = (crack * 0.55 + core * 0.65) * open * flicker * (0.5 + 0.5 * clamp(uBusy + uPower, 0.0, 1.0));
        col += mix(cyan, ice, core) * leak;
      }
      float lockFlash = smoothstep(0.0, 0.08, uImpact) * exp(-impact * 5.0) * impacting;
      float swallow = closeActive * exp(-(closing - 0.62) * (closing - 0.62) / 0.006);
      col += ice * exp(-reach / 0.9) * (lockFlash * 0.45 + swallow * 0.18);

      float mask = logoCover(logoMask, glyph, uSpin, uSpinBlur, gap);
      if (mask > 0.0) {
        // The light leaves a soft spot on the glyph on the same side as its highlights on the ring.
        float2 glossCenter = slant * 0.5;
        float gloss = exp(-dot(glyph - glossCenter, glyph - glossCenter) / 0.16);
        float silk = 0.5 + 0.5 * sin(spun.x * 5.0 + spun.y * 4.0 - t * 1.8
          - dot(slant, float2(0.75, 0.55)));
        float sheen = 0.14 + 0.18 * silk + gloss * (0.34 + 0.18 * uPower + 0.08 * uBusy + 0.55 * lean);
        float3 logo = mix(cyan * 0.80, ice, clamp(sheen, 0.0, 1.0));
        float trace = pow(clamp(0.5 + 0.5 * sin(spun.x * 12.0 - spun.y * 22.0 - t * 2.2), 0.0, 1.0), 8.0);
        logo += ice * trace * uBusy * 0.055;
        logo += ice * crack * open * 0.35;
        logo = mix(logo, float3(0.96, 0.985, 1.0), clamp(lockFlash * 0.75 + swallow * 0.3, 0.0, 1.0));
        col = mix(col, logo, mask);
      }
    }
  }
  return half4(half3(clamp(col, 0.0, 1.0) * opacity), half(opacity));
}
