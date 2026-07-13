import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/layout_tokens.dart';
import '../../services/app_storage.dart';
import '../../services/download_service.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/stable_backdrop_group.dart';

/// Pantalla que muestra DÓNDE guarda Vibra la música descargada y las
/// carpetas de sistema de la app, con acciones para copiar la ruta.
///
/// Filosofía de permisos: las descargas van a `Android/media/<pkg>/`, la
/// carpeta de medios PROPIA de la app — es pública (visible en el
/// explorador) pero NO requiere `WRITE_EXTERNAL_STORAGE` ni
/// `MANAGE_EXTERNAL_STORAGE`. Por eso esta pantalla no pide permisos:
/// la app ya puede escribir ahí. Solo informa y da acceso a la ruta.
class StorageSettingsScreen extends StatelessWidget {
  const StorageSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final downloads = context.watch<DownloadService?>();
    final storageReady = AppStorage.isInitialized;
    final storage = storageReady ? AppStorage.instance : null;
    final scheme = Theme.of(context).colorScheme;

    return StableBackdropGroup(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('Almacenamiento')),
        body: ListView(
          padding: tokens.pagePadding(),
          children: [
            // ─────────── Dónde vive la música ───────────
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.folder_special_rounded,
                          size: 28, color: scheme.primary),
                      SizedBox(width: tokens.gap),
                      Expanded(
                        child: Text('Música descargada',
                            style:
                                Theme.of(context).textTheme.titleMedium),
                      ),
                    ],
                  ),
                  SizedBox(height: tokens.gapSm),
                  if (downloads != null) ...[
                    Text(
                      downloads.isPublicStorage
                          ? 'Tus descargas se guardan en una carpeta '
                              'pública. Puedes verlas y copiarlas desde el '
                              'explorador de archivos, y otras apps de '
                              'música las detectan automáticamente.'
                          : 'Tus descargas se guardan en el almacenamiento '
                              'interno de la app (no visible desde el '
                              'explorador de archivos en esta plataforma).',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    SizedBox(height: tokens.gap),
                    _PathTile(
                      label: 'Carpeta',
                      // Mostramos la ruta "amigable" desde Android/… si es
                      // pública; el path completo tiene el prefijo del
                      // storage montado que confunde.
                      path: _friendlyPath(downloads.downloadsPath),
                      fullPath: downloads.downloadsPath,
                    ),
                    if (downloads.isPublicStorage) ...[
                      SizedBox(height: tokens.gapSm),
                      Row(
                        children: [
                          Icon(Icons.check_circle_rounded,
                              size: 16, color: scheme.primary),
                          const SizedBox(width: 6),
                          Text('Visible en el explorador de archivos',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: scheme.primary)),
                        ],
                      ),
                    ],
                  ] else
                    Text(
                      'El servicio de descargas no está disponible.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),

            // ─────────── Carpetas de sistema de la app ───────────
            if (storageReady && !kIsWeb && Platform.isAndroid) ...[
              SizedBox(height: tokens.gap),
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Carpetas de sistema',
                        style: Theme.of(context).textTheme.titleMedium),
                    SizedBox(height: tokens.gapSm),
                    Text(
                      'Vibra crea sus tres carpetas propias bajo el '
                      'almacenamiento de Android. No requieren permisos '
                      'especiales.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    SizedBox(height: tokens.gap),
                    if (storage!.mediaDir != null)
                      _PathTile(
                        label: 'Android/media',
                        path: _friendlyPath(storage.mediaDir!),
                        fullPath: storage.mediaDir!,
                        subtitle: 'Pública · música descargada',
                      ),
                    if (storage.filesDir != null) ...[
                      SizedBox(height: tokens.gapSm),
                      _PathTile(
                        label: 'Android/data',
                        path: _friendlyPath(storage.filesDir!),
                        fullPath: storage.filesDir!,
                        subtitle: 'Privada · datos de la app',
                      ),
                    ],
                    if (storage.obbDir != null) ...[
                      SizedBox(height: tokens.gapSm),
                      _PathTile(
                        label: 'Android/obb',
                        path: _friendlyPath(storage.obbDir!),
                        fullPath: storage.obbDir!,
                        subtitle: 'Reservada',
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Recorta el prefijo del punto de montaje (`/storage/emulated/0/`) para
  /// mostrar la ruta relativa a la raíz del almacenamiento — más legible
  /// y coincide con lo que el usuario ve en el explorador.
  static String _friendlyPath(String full) {
    const prefixes = [
      '/storage/emulated/0/',
      '/sdcard/',
    ];
    for (final p in prefixes) {
      if (full.startsWith(p)) return full.substring(p.length);
    }
    // Buscar "/Android/" y mostrar desde ahí.
    final idx = full.indexOf('/Android/');
    if (idx >= 0) return full.substring(idx + 1);
    return full;
  }
}

class _PathTile extends StatelessWidget {
  const _PathTile({
    required this.label,
    required this.path,
    required this.fullPath,
    this.subtitle,
  });

  final String label;
  final String path;
  final String fullPath;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy_rounded, size: 18),
                tooltip: 'Copiar ruta',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: fullPath));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Ruta copiada'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
              ),
            ],
          ),
          SelectableText(
            path,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurface.withValues(alpha: 0.55),
                  ),
            ),
          ],
        ],
      ),
    );
  }
}
