#version 460 core
#include <flutter/runtime_effect.glsl>

// Lava lamp / metaballs — esferas de "líquido" se atraen visualmente y
// generan formas orgánicas. Toma colores del tema:
//   - u_color1 = highlight (esferas centrales saturadas).
//   - u_color2 = mid (esferas exteriores).
//   - u_color3 = base oscura (fondo donde la metaball es débil).

uniform vec2  u_resolution;
uniform float u_time;
uniform vec4  u_color1;
uniform vec4  u_color2;
uniform vec4  u_color3;
uniform float u_speed;

out vec4 fragColor;

float metaball(vec2 p, vec2 c, float r) {
  return r / max(length(p - c), 1e-4);
}

void main() {
  vec2 uv = FlutterFragCoord().xy / u_resolution.xy;
  vec2 p = uv * 2.0 - 1.0;
  p.x *= u_resolution.x / u_resolution.y;

  float t = u_time * u_speed * 0.45;

  vec2 c1 = vec2(sin(t * 0.70)        * 0.60, cos(t * 0.90)        * 0.50);
  vec2 c2 = vec2(cos(t * 0.80)        * 0.70, sin(t * 1.10)        * 0.55);
  vec2 c3 = vec2(sin(t * 1.20 + 1.0)  * 0.40, cos(t * 0.60)        * 0.65);

  float m = metaball(p, c1, 0.25)
          + metaball(p, c2, 0.30)
          + metaball(p, c3, 0.22);

  float mix1 = smoothstep(0.80, 1.60, m);
  float mix2 = smoothstep(1.60, 2.40, m);

  vec3 col = mix(u_color3.rgb, u_color2.rgb, mix1);
  col = mix(col, u_color1.rgb, mix2);

  fragColor = vec4(col, 1.0);
}
