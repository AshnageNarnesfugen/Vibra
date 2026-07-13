#version 460 core
#include <flutter/runtime_effect.glsl>

// Plasma clásico — combinación de sinusoides en 2D que producen el patrón
// fluido típico de los efectos demoscene. Palette-aware con 3 colores.

uniform vec2  u_resolution;
uniform float u_time;
uniform vec4  u_color1;
uniform vec4  u_color2;
uniform vec4  u_color3;
uniform float u_speed;

out vec4 fragColor;

void main() {
  vec2 uv = (FlutterFragCoord().xy / u_resolution.xy) * 2.0 - 1.0;
  // Corrige aspecto — sin esto el patrón se estira en pantallas verticales.
  uv.x *= u_resolution.x / u_resolution.y;

  float t = u_time * u_speed * 0.5;

  // Suma de 4 fuentes de plasma. Las dos últimas tienen un centro que se
  // desplaza con el tiempo → el patrón nunca se siente estático.
  float v = sin(uv.x * 4.0 + t);
  v += sin((uv.y * 4.0 + t) * 0.5);
  v += sin((uv.x + uv.y + t) * 3.0);

  float cx = uv.x + 0.5 * sin(t * 0.30);
  float cy = uv.y + 0.5 * cos(t * 0.40);
  v += sin(sqrt(cx * cx + cy * cy + 1.0) * 4.0 + t);

  v *= 0.25;

  float m1 = sin(v * 3.14159) * 0.5 + 0.5;
  float m2 = cos(v * 3.14159 + 1.0) * 0.5 + 0.5;

  vec3 col = mix(u_color1.rgb, u_color2.rgb, m1);
  col = mix(col, u_color3.rgb, m2 * 0.55);

  fragColor = vec4(col, 1.0);
}
