import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/layout_tokens.dart';
import '../services/streaming/streaming_service.dart';
import '../widgets/shelf_cards.dart';

/// Pantalla "Ver todo": muestra la lista completa de items de un shelf
/// (álbumes, singles, canciones, artistas relacionados) en un grid o lista
/// vertical, en vez del carrusel horizontal del HomeCarousel.
///
/// Cuando se le pasa [moreBrowseId] + [moreParams], hace fetch async al
/// endpoint "Ver todo" de YT Music para obtener la lista COMPLETA (los
/// 30+ álbumes/singles reales del artista, no los ~10 del shelf inicial).
/// Mientras carga, muestra los items iniciales como preview + spinner.
class ShelfFullScreen extends StatefulWidget {
  const ShelfFullScreen({
    super.key,
    required this.title,
    required this.initialItems,
    required this.onTapItem,
    this.moreBrowseId,
    this.moreParams,
  });

  final String title;
  final List<ShelfItem> initialItems;
  final void Function(ShelfItem) onTapItem;
  final String? moreBrowseId;
  final String? moreParams;

  @override
  State<ShelfFullScreen> createState() => _ShelfFullScreenState();
}

class _ShelfFullScreenState extends State<ShelfFullScreen> {
  late List<ShelfItem> _items = widget.initialItems;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.moreBrowseId != null) {
      _fetchFull();
    }
  }

  Future<void> _fetchFull() async {
    final id = widget.moreBrowseId;
    if (id == null) return;
    setState(() => _loading = true);
    try {
      final svc = context.read<StreamingService>();
      final full = await svc.getShelfFull(id, widget.moreParams);
      if (!mounted) return;
      if (full.isNotEmpty) {
        setState(() {
          _items = full;
          _loading = false;
        });
      } else {
        setState(() => _loading = false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    // Detecta si la lista es de artistas (avatares circulares) o álbumes/
    // playlists/canciones (tiles cuadrados). Si son MIXTOS, el primer item
    // gana — caso edge raro en YT Music.
    final isArtistList =
        _items.isNotEmpty && _items.first.kind == ShelfItemKind.artist;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: [
          if (_items.isEmpty && _loading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_items.isEmpty && _error != null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text('Error al cargar: $_error',
                      textAlign: TextAlign.center),
                ),
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                  tokens.space(20), tokens.gap, tokens.space(20), 0),
              sliver: SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: isArtistList ? 130 : 180,
                  mainAxisExtent: isArtistList ? 160 : 220,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: _items.length,
                itemBuilder: (context, i) {
                  final item = _items[i];
                  if (isArtistList) {
                    return SmallArtistCard(
                      item: item,
                      onTap: () => widget.onTapItem(item),
                    );
                  }
                  return SmallShelfCard(
                    item: item,
                    onTap: () => widget.onTapItem(item),
                  );
                },
              ),
            ),
          SliverToBoxAdapter(
            child: SizedBox(
                height: 200 + MediaQuery.viewPaddingOf(context).bottom),
          ),
        ],
      ),
    );
  }
}
