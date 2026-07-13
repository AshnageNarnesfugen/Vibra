#version 460 core
#include <flutter/runtime_effect.glsl>

// Aurora boreal — bandas verticales suaves que ondulan y se mezclan con un
// noise pseudo-aleatorio. Palette-aware: usa 3 colores del tema.

uniform vec2  u_resolution;
uniform float u_time;
uniform vec4  u_color1; // brillo superior (acento del album)
uniform vec4  u_color2; // medio (color dominante)
uniform vec4  u_color3; // base inferior (oscuro)
uniform float u_speed;

out vec4 fragColor;

float hash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  float a = hash(i);
  float b = hash(i + vec2(1.0, 0.0));
  float c = hash(i + vec2(0.0, 1.0));
  float d = hash(i + vec2(1.0, 1.0));
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

void main() {
  vec2 uv = FlutterFragCoord().xy / u_resolution.xy;
  float t = u_time * u_speed * 0.35;

  // Ondulación horizontal multifrecuencia.
  float w = sin(uv.x * 3.0 + t) * 0.5
          + sin(uv.x * 7.0 - t * 1.3) * 0.25
          + sin(uv.x * 13.0 + t * 0.6) * 0.12;
  w = w * 0.5 + 0.5;

  // Noise vertical para textura aurora.
  float n = noise(uv * vec2(3.0, 8.0) + vec2(t * 0.5, t));

  // Banda principal del aurora — sube y baja con el noise.
  float band = smoothstep(0.30, 0.85, uv.y + n * 0.20 + w * 0.18);

  // Mezcla: base oscura → medio → brillo.
  vec3 col = mix(u_color3.rgb * 0.55,
                 u_color2.rgb,
                 smoothstep(0.0, 0.65, uv.y + n * 0.10));
  col = mix(col, u_color1.rgb, band);

  // Vignette circular sutil.
  float vig = 1.0 - smoothstep(0.55, 1.30, length((uv - 0.5) * vec2(1.0, 1.4)));
  col *= 0.72 + vig * 0.55;

  fragColor = vec4(col, 1.0);
}
