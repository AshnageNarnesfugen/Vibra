/// Catálogo de shaders GLSL disponibles como fondo animado.
///
/// Cada shader vive en `assets/shaders/<asset>.frag` y se declara en
/// `pubspec.yaml` bajo `flutter.shaders:`. El widget [ShaderBackground]
/// carga el program y lo pinta en loop.
///
/// **paletteAware**: si es `true`, el shader recibe los 3 colores de la
/// paleta del album (dominante / acento / oscuro). Si `false`, el shader
/// tiene su propia paleta artística fija (los uniforms de color se ignoran).
enum BackgroundShader {
  aurora(
    asset: 'assets/shaders/aurora.frag',
    label: 'Aurora',
    description: 'Bandas verticales suaves estilo aurora boreal.',
    paletteAware: true,
  ),
  plasma(
    asset: 'assets/shaders/plasma.frag',
    label: 'Plasma',
    description: 'Patrón clásico de demoscene con sinusoides fluidas.',
    paletteAware: true,
  ),
  mesh(
    asset: 'assets/shaders/mesh.frag',
    label: 'Mesh Gradient',
    description: 'Cuatro puntos de color orbitando con blending gaussiano.',
    paletteAware: true,
  ),
  liquid(
    asset: 'assets/shaders/liquid.frag',
    label: 'Lava Lamp',
    description: 'Metaballs orgánicos con los colores del album.',
    paletteAware: true,
  );

  const BackgroundShader({
    required this.asset,
    required this.label,
    required this.description,
    required this.paletteAware,
  });

  final String asset;
  final String label;
  final String description;
  final bool paletteAware;
}
