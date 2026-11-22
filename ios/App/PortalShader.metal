// Ported from the approved C2 button preview in docs/brand/portal-shader-concept.html.
#include <metal_stdlib>
using namespace metal;

// Matches PortalEffect.Uniforms: 256 bytes, tilt at 32, logoRect at 48, press at 68, packets at 80, light at 176,
// traffic at 192, ripples at 208.
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
    // Connected traffic, placed by PortalFlow: 0 when there is none, 1 from about 2 MB/s on a logarithmic scale; drift is
    // how far it has carried the packets that run through the passage.
    float traffic;
    float drift;
    // Rises and falls about twelve times a minute while connected, 0...1.
    float breath;
    // Ripples that traffic drops into the membrane, placed by PortalFlow: the unit vector to where each fell on the rim,
    // its age in seconds, and its strength, 0 once it has died away.
    float4 ripples[3];
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
constexpr sampler noiseSampler(coord::normalized, address::repeat, filter::linear);
float hash(float2 p) {
  p = fract(p * float2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}
// Four octaves of value noise, baked by PortalNoise into a texture of 16 noise cells to a side.
float fbm(texture2d<float> noise, float2 p) {
  return noise.sample(noiseSampler, p / 16.0).r;
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
                              texture2d<float> logoMask [[texture(0)]], texture2d<float> noise [[texture(2)]]) {
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
    float uTraffic = uniforms.traffic;
    float uDrift = uniforms.drift;
    float uBreath = uniforms.breath;
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

  // Opening, counted in seconds from when the tunnel comes up: light gathers in the logo for a breath, a lens of light
  // bursts from it past the ring, falls back into a membrane across the ring, ripples and clears to show the other side.
  float opening = uImpact;
  float impacting = opening < 2.5 ? 1.0 : 0.0;
  float r = length(p);
  // The lens's front strikes the ring as it passes, and the ring rings.
  float hitAge = opening - 0.40;
  float hit = hitAge > 0.0 ? impacting : 0.0;
  float kick = hit * exp(-hitAge * 7.0) * sin(hitAge * 30.0);
  float surge = hit * exp(-hitAge * 3.5);

  float closeActive = uClose < 1.0 ? 1.0 : 0.0;
  float closing = uClose * closeActive;
  float squeeze = sin(PI * smoothstep(0.0, 0.7, closing)) * closeActive;
  // A press squeezes the ring and lights it, so the whole portal answers the finger.
  float energy = 0.19 + uPower * 0.71 + uBusy * 0.65 + surge * 0.9 + uPress * 0.35;
  // The ring dims for the breath before the burst; connected, it breathes with the membrane.
  float inhale = smoothstep(0.0, 0.08, opening) * (1.0 - smoothstep(0.12, 0.24, opening)) * impacting;
  energy *= (1.0 - 0.14 * inhale) * (1.0 + 0.10 * (uBreath - 0.5) * uPower);
  float radius = 0.588 - 0.06 * squeeze + 0.022 * kick - 0.014 * uPress;
  // The lens's front: out past the ring by 0.45 s, then back onto it with a bounce, where the membrane stays.
  float front = 0.0;
  if (opening >= 0.45) {
    float settling = opening - 0.45;
    front = radius - 0.03 + (0.70 - radius) * exp(-settling * 7.0) * cos(settling * 12.0);
  } else if (opening >= 0.15) {
    float rest = 1.0 - (opening - 0.15) / 0.30;
    front = 0.67 * (1.0 - rest * rest * rest);
  }
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
  float flow = abs(ringDistance) < 0.2 ? fbm(noise, circle * 3.4 + float2(t * 0.24, -t * 0.19)) : 0.5;
  float warp = (flow - 0.5) * (0.008 + 0.045 * uBusy) * (1.0 - smoothstep(0.14, 0.2, abs(ringDistance)));
  float d = ringDistance - warp;
  float3 bg = mix(float3(0.047, 0.094, 0.122), float3(0.053, 0.175, 0.232), exp(-r * r * 1.7) * 0.72);
  float grain = (hash(position) - 0.5) * 0.007;
  float3 col = bg + grain;
  // Connected, a membrane spans the ring. It shows the other side: dim hazy depth that tilt moves and traffic flows through.
  float span = 0.0;
  if (uPower > 0.001 && front > 0.0 && r < radius) {
    float collapse = 1.0;
    if (closeActive > 0.0) {
      // Closing, it drains into the logo with the ring's light.
      float drain = smoothstep(0.04, 0.62, closing);
      collapse = 1.0 - smoothstep(radius * (1.0 - drain) - 0.06, radius * (1.0 - drain), length(p - logoP * drain));
    }
    span = min(uPower * 1.4, 1.0) * collapse * (1.0 - smoothstep(front - 0.025, front + 0.004, r))
      * (1.0 - smoothstep(radius - 0.05, radius - 0.018, r));
  }
  if (span > 0.0) {
    // The lens bulges towards the viewer, overshoots into a hollow as it falls back, and settles flat.
    float bulgeAge = opening - 0.40;
    float bulge = opening < 0.15 || opening > 2.0 ? 0.0
      : bulgeAge < 0.0 ? smoothstep(0.15, 0.40, opening) : exp(-bulgeAge * 6.0) * cos(bulgeAge * 10.0);
    float lensRadius = max(front, 0.2);
    float2 slope = -circle * (bulge * 0.18 * r / (lensRadius * lensRadius));
    // Two rings roll out from the logo, where the lens fell back.
    float2 fromLogo = p - logoP;
    float logoR = length(fromLogo);
    if (opening > 0.72 && opening < 3.4) {
      for (int i = 0; i < 2; i++) {
        float age = opening - 0.72 - 0.2 * float(i);
        float wave = logoR - age * 0.48;
        slope += fromLogo / max(logoR, 0.0001) * (-2.0 * wave / 0.0025) * exp(-wave * wave / 0.0025) * 0.009 * exp(-age * 2.0)
          * smoothstep(0.0, 0.25, age);
      }
    }
    // Traffic drops ripples in where it crosses the rim; their crests catch a little light.
    float crests = 0.0;
    for (int i = 0; i < 3; i++) {
      float4 ripple = uniforms.ripples[i];
      if (ripple.w > 0.0) {
        float2 fromDrop = p - ripple.xy * (radius - 0.05);
        float dropR = length(fromDrop);
        float wave = dropR - ripple.z * 0.42;
        float fade = ripple.w * (1.0 - ripple.z / 1.6) * smoothstep(0.0, 0.15, ripple.z);
        slope += fromDrop / max(dropR, 0.0001) * (-2.0 * wave / 0.002) * exp(-wave * wave / 0.002) * 0.008 * fade;
        crests += exp(-wave * wave / 0.0005) * fade;
      }
    }
    // The other side lies deep behind the ring, so tilt slides it further than the ring; ripples bend it, and the
    // membrane's curve near the rim draws more of it into view.
    float clearing = smoothstep(1.0, 2.0, opening);
    float bend = smoothstep(0.2, radius, r);
    float2 q = (p + uTilt * 0.10 + slope * 0.35) * (1.0 + 0.45 * bend * bend);
    float rq = length(q);
    float2 inward = q / max(rq, 0.0001);
    // Depth along the passage, which drops away from the viewer as it clears and then stands still.
    float depth = 0.22 / max(rq, 0.03);
    float settled = depth - 0.9 * (1.0 - exp(-max(opening - 1.0, 0.0) * 2.2));
    float fog = exp(-depth * 0.55);
    float nearFade = smoothstep(0.03, 0.16, rq);
    float ribOffset = fract(settled) - 0.5;
    float rib = exp(-ribOffset * ribOffset * 100.0) * fog * nearFade;
    // The haze is read along the passage, so it recedes with the depth and grows finer towards the far end.
    float haze = fbm(noise, inward * (1.4 + settled * 0.9));
    float3 beyond = mix(float3(0.016, 0.050, 0.072), float3(0.030, 0.130, 0.185), haze * fog) + deep * rib * 0.30;
    if (uTraffic > 0.001) {
      // Packets run along lanes of the passage, into it on seven and out of it on six; the lanes come from powers of
      // the unit vector, so no atan.
      float2 inward2 = float2(inward.x * inward.x - inward.y * inward.y, 2.0 * inward.x * inward.y);
      float2 inward4 = float2(inward2.x * inward2.x - inward2.y * inward2.y, 2.0 * inward2.x * inward2.y);
      float2 inward6 = float2(inward4.x * inward2.x - inward4.y * inward2.y, inward4.x * inward2.y + inward4.y * inward2.x);
      float2 inward7 = float2(inward6.x * inward.x - inward6.y * inward.y, inward6.x * inward.y + inward6.y * inward.x);
      float stagger = fbm(noise, inward * 1.4 + 5.0);
      float leaving = fract((settled - uDrift) * 0.8 + stagger * 3.0) - 0.5;
      float arriving = fract(-(settled + uDrift * 1.3333) * 0.6 + stagger * 4.0) - 0.5;
      float lanes = pow(0.5 + 0.5 * inward7.x, 30.0) * exp(-leaving * leaving / 0.006)
        + pow(0.5 + 0.5 * (inward6.x * 0.5 - inward6.y * 0.866), 30.0) * exp(-arriving * arriving / 0.006);
      beyond += cyan * lanes * fog * nearFade * uTraffic * 0.9;
    }
    beyond *= clearing * (0.92 + 0.16 * uBreath);
    // The membrane: lit from inside while the lens bursts, then a clear film that only catches light.
    float3 halfway = normalize(normalize(float3(light.xy, max(light.z, 0.25))) + float3(0.0, 0.0, 1.0));
    float veil = 1.0 - clearing;
    float3 membrane = deep * (0.10 + 0.22 * smoothstep(radius * 0.5, radius - 0.03, r)) * (0.6 + 0.4 * veil)
      + float3(0.02, 0.07, 0.10) * veil * veil;
    // Still, the film catches the light the same everywhere; ripples and the lens bend it into highlights and shade.
    float spec = pow(halfway.z, 80.0);
    if (dot(slope, slope) > 0.0) {
      spec = pow(max(dot(normalize(float3(-slope * 0.9, 1.0)), halfway), 0.0), 80.0);
      float shade = dot(-slope, lightDir) * aim;
      membrane += mix(deep * 0.5, cyan, step(0.0, shade)) * min(abs(shade) * 3.0, 1.0) * 0.10
        + mix(cyan, ice, 0.3) * crests * 0.26 * (0.6 + 0.4 * aim);
    }
    membrane += ice * spec * (0.35 + 0.45 * lean);
    if (bulge > 0.0) {
      float reach = r * r / (lensRadius * lensRadius);
      membrane += cyan * bulge * (0.16 + 0.55 * reach * reach) + ice * bulge * bulge * exp(-logoR * logoR / 0.025) * 0.45;
    }
    // Light that the membrane bends round the rim.
    if (abs(r - radius + 0.052) < 0.02) membrane += ice * band(r - radius + 0.052, 0.0045) * 0.22 * clearing;
    col = mix(col, beyond + membrane, span);
  }
  // The burst's front: a white edge trailing deep cyan, carried past the ring before it falls back onto it.
  if (front > 0.0 && opening < 1.2 && uPower > 0.001) {
    float frontFade = smoothstep(0.15, 0.2, opening) * exp(-max(opening - 0.42, 0.0) * 6.0);
    float edge = r - front;
    col += ice * band(edge, 0.005) * frontFade * 0.9 + deep * band(edge + 0.012, 0.009) * frontFade * 0.7;
    col += cyan * band(edge, 0.035) * frontFade * 0.25;
    // Light thrown out across the page as the front strikes the ring.
    float thrown = opening - 0.40;
    if (thrown > 0.0) col += cyan * band(r - radius - thrown * 0.75, 0.012 + thrown * 0.05) * exp(-thrown * 3.5) * 0.35;
  }
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

    float edgeFlow = fbm(noise, circle * 6.0 + float2(t * 0.38, t * 0.2));
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
      float haze = fbm(noise, p * 4.8 + float2(t * 0.13, -t * 0.22));
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
        float flicker = 0.7 + 0.3 * fbm(noise, spun * 3.0 + float2(t * 1.7, -t * 1.3));
        float leak = (crack * 0.55 + core * 0.65) * open * flicker * (0.5 + 0.5 * clamp(uBusy + uPower, 0.0, 1.0));
        col += mix(cyan, ice, core) * leak;
      }
      float lockFlash = smoothstep(0.0, 0.12, opening) * exp(-max(opening - 0.14, 0.0) * 9.0) * impacting;
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
  // Light past 0.85 rolls off towards white instead of clipping (the shoulder of Khronos PBR Neutral, without its toe).
  float peak = max(col.r, max(col.g, col.b));
  if (peak > 0.85) {
    float rolled = 1.0 - 0.0225 / (peak - 0.70);
    col *= rolled / peak;
    col = mix(col, float3(rolled), 1.0 - 1.0 / (0.15 * (peak - rolled) + 1.0));
  }
  return half4(half3(clamp(col, 0.0, 1.0) * opacity), half(opacity));
}
