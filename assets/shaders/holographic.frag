#version 460 core
#include <flutter/runtime_effect.glsl>

// Papel holográfico iridiscente palette-aware. En vez de un espectro
// RGB completo (que se ve "neón" sobre cualquier portada), interpolamos
// entre 3 colores del album → el holo "viste" la portada en tonos que
// pertenecen visualmente al track.
//
// Performance: 2 sin calls (antes 3), sin sparkle (antes hash+pow por
// pixel que era el cost dominante), sin HSV→RGB. En Retroid Pocket
// Flip2 (Snapdragon 720G) el frame budget cae de ~6ms a ~1.5ms.

uniform vec2  u_resolution;
uniform float u_time;
uniform vec4  u_color1; // dominant del album
uniform vec4  u_color2; // accent
uniform vec4  u_color3; // light variant
uniform float u_tiltX;  // -1..1 (gyro normalizado)
uniform float u_tiltY;

out vec4 fragColor;

void main() {
  vec2 uv = FlutterFragCoord().xy / u_resolution.xy;
  vec2 centered = uv - 0.5;

  // Tilt shifts the apparent viewing angle.
  vec2 tilt = vec2(u_tiltX, u_tiltY) * 0.5;

  // Onda diagonal multifrecuencia. El tilt entra cruzado en cada eje
  // → al rotar el device en X las bandas se desplazan en Y (efecto
  // físico de "ver desde otro ángulo").
  float t = u_time * 0.12;
  float wave =
      sin((centered.x + tilt.y) * 9.0 + (centered.y - tilt.x) * 7.0 + t) * 0.5
    + sin((centered.x - tilt.y) * 17.0 - (centered.y + tilt.x) * 13.0 - t * 1.4) * 0.5;
  wave = wave * 0.5 + 0.5; // 0..1

  // Banda 0..1 que cicla 2× sobre wave + tilt → más "bandas" visibles
  // sobre la superficie cuando el device se mueve.
  float band = fract(wave * 2.0 + tilt.x * 0.7 + tilt.y * 0.7);

  // Interpolación 3-stops entre los colores del album.
  vec3 col;
  if (band < 0.5) {
    col = mix(u_color1.rgb, u_color2.rgb, band * 2.0);
  } else {
    col = mix(u_color2.rgb, u_color3.rgb, (band - 0.5) * 2.0);
  }

  // Vignette suave.
  float vig = smoothstep(1.05, 0.30, length(centered));

  // Alpha calibrado para srcOver (no plus): 0.42 deja ver el cover
  // por debajo en transparencia mientras el holo se nota arriba. Sin
  // saveLayer (que blend plus exigía) eliminamos ~5-15ms del frame
  // budget en mid-range — el stuttering se va.
  float alpha = 0.42 * vig;

  // Pre-multiplied alpha: con srcOver default Flutter espera el shader
  // output en formato premultiplied. col * alpha en RGB → al componer
  // con el cover (srcOver), Skia hace `dst = src + (1-src.a)*dst`.
  fragColor = vec4(col * alpha, alpha);
}
