#version 460 core

// Nearby reveal: one sonar wavefront travels out from the touch point and
// bends the captured screen as it passes, like heat haze over water.
#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;     // logical size of the captured screen
uniform vec2 uCenter;   // wavefront origin, logical pixels
uniform float uTime;    // 0 at the touch, 1 when the wave has left the screen
uniform float uStrength;
uniform vec3 uTint;
uniform sampler2D uImage;

out vec4 fragColor;

void main() {
  vec2 p = FlutterFragCoord().xy;
  vec2 d = p - uCenter;
  float dist = length(d);
  float radius = uTime * length(uSize) * 1.05;
  float band = 70.0 + 60.0 * uTime;
  float x = (dist - radius) / band;
  float envelope = exp(-x * x);
  float fade = 1.0 - smoothstep(0.55, 1.0, uTime);
  vec2 dir = dist > 0.001 ? d / dist : vec2(0.0);
  // The wavefront pushes pixels outward then lets them fall back behind it.
  vec2 offset = dir * sin(x * 6.2831) * envelope * uStrength * fade;
  // A faint wobble everywhere the wave has already crossed.
  float crossed = smoothstep(radius, radius - band * 2.0, dist);
  offset += vec2(sin(p.y * 0.045 + uTime * 26.0), cos(p.x * 0.045 + uTime * 22.0))
      * 2.2 * crossed * fade;
  vec2 uv = clamp((p - offset) / uSize, vec2(0.0), vec2(1.0));
  vec4 color = texture(uImage, uv);
  float ring = exp(-x * x * 6.0) * fade;
  color.rgb = mix(color.rgb, uTint, ring * 0.28);
  fragColor = color;
}
