#version 460 core
#include <flutter/runtime_effect.glsl>

// Mesh gradient — 4 puntos de control con colores que se desplazan
// suavemente. El blending es por gaussianas inversamente ponderadas — da el
// look "gradient mesh" que está de moda en visual design (Apple, Stripe).

uniform vec2  u_resolution;
uniform float u_time;
uniform vec4  u_color1;
uniform vec4  u_color2;
uniform vec4  u_color3;
uniform float u_speed;

out vec4 fragColor;

float gaussian(vec2 p, vec2 c, float r) {
  vec2 d = p - c;
  return exp(-(d.x * d.x + d.y * d.y) / (r * r));
}

void main() {
  vec2 uv = FlutterFragCoord().xy / u_resolution.xy;
  float t = u_time * u_speed * 0.40;

  // 4 puntos que orbitan suavemente.
  vec2 p1 = vec2(0.20 + sin(t)        * 0.15, 0.30 + cos(t * 0.70) * 0.15);
  vec2 p2 = vec2(0.80 + cos(t * 1.10) * 0.15, 0.70 + sin(t * 0.90) * 0.15);
  vec2 p3 = vec2(0.50 + sin(t * 1.30) * 0.20, 0.20 + cos(t * 0.60) * 0.15);
  vec2 p4 = vec2(0.50 + cos(t * 0.50) * 0.20, 0.85 + sin(t * 1.20) * 0.10);

  float r = 0.50;
  float w1 = gaussian(uv, p1, r);
  float w2 = gaussian(uv, p2, r);
  float w3 = gaussian(uv, p3, r);
  float w4 = gaussian(uv, p4, r);
  float sum = w1 + w2 + w3 + w4 + 0.001;

  vec3 mix12 = mix(u_color1.rgb, u_color2.rgb, 0.5);
  vec3 col = (u_color1.rgb * w1
            + u_color2.rgb * w2
            + u_color3.rgb * w3
            + mix12        * w4) / sum;

  fragColor = vec4(col, 1.0);
}
