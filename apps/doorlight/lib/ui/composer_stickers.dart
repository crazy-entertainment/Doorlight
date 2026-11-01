import 'package:flutter/material.dart';
import 'dart:typed_data';

import '../state/sticker_manifest.dart';
import '../state/composer_emoji.dart';
import '../state/gif_library_store.dart';
import '../state/starter_gifs.dart';
import '../state/gif_recents.dart';
import 'bounded_gif.dart';
import 'gravity.dart';
import 'sticker_image.dart';

class ComposerPicker extends StatelessWidget {
  const ComposerPicker({
    super.key,
    required this.onSticker,
    required this.onEmoji,
    required this.onImportGif,
    this.gifLibrary,
    this.gifRevision,
    this.onGif,
    this.onStarterGif,
  });
  final ValueChanged<BuiltInSticker> onSticker;
  final ValueChanged<String> onEmoji;
  final VoidCallback? onImportGif;
  final GifLibraryStore? gifLibrary;
  final Object? gifRevision;
  final ValueChanged<String>? onGif;
  final ValueChanged<StarterGif>? onStarterGif;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    initialIndex: 1,
    child: Column(
      children: [
        const TabBar(
          tabs: [
            Tab(text: 'Emoji'),
            Tab(text: 'Stickers'),
            Tab(text: 'GIFs'),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              SingleChildScrollView(
                child: Wrap(
                  children: [
                    for (final emoji in composerEmoji)
                      SizedBox(
                        width: 48,
                        height: 48,
                        child: Gravity(
                          child: TextButton(
                            onPressed: () => onEmoji(emoji),
                            child: Text(
                              emoji,
                              style: const TextStyle(fontSize: 24),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              ComposerStickers(onSelected: onSticker),
              _GifShelves(
                library: gifLibrary,
                revision: gifRevision,
                onImport: onImportGif,
                onPersonal: onGif,
                onStarter: onStarterGif,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _GifShelves extends StatefulWidget {
  const _GifShelves({
    this.library,
    this.revision,
    this.onImport,
    this.onPersonal,
    this.onStarter,
  });
  final GifLibraryStore? library;
  final Object? revision;
  final VoidCallback? onImport;
  final ValueChanged<String>? onPersonal;
  final ValueChanged<StarterGif>? onStarter;

  @override
  State<_GifShelves> createState() => _GifShelvesState();
}

class _GifShelvesState extends State<_GifShelves> {
  bool _personal = false;
  late Future<bool>? _loaded = widget.library?.reload();

  @override
  void didUpdateWidget(_GifShelves oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != widget.library ||
        oldWidget.revision != widget.revision) {
      _loaded = widget.library?.reload();
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Gravity(
              child: ChoiceChip(
                label: const Text('Doorlight'),
                selected: !_personal,
                onSelected: (_) => setState(() => _personal = false),
              ),
            ),
            const SizedBox(width: 8),
            Gravity(
              child: ChoiceChip(
                label: const Text('Your GIFs'),
                selected: _personal,
                onSelected: (_) => setState(() => _personal = true),
              ),
            ),
          ],
        ),
      ),
      Expanded(
        child: !_personal
            ? FutureBuilder<bool>(
                future: _loaded,
                builder: (context, _) => _StarterGifShelf(
                  onSelected: widget.onStarter,
                  recents: widget.library?.recents,
                ),
              )
            : widget.library != null
            ? _ComposerGifLibrary(
                key: ValueKey(widget.revision),
                store: widget.library!,
                onImport: widget.onImport,
                onSelected: widget.onPersonal,
              )
            : Center(
                child: Gravity(
                  child: FilledButton.icon(
                    onPressed: widget.onImport,
                    icon: const Icon(Icons.add),
                    label: const Text('Import GIF'),
                  ),
                ),
              ),
      ),
    ],
  );
}

class _StarterGifShelf extends StatelessWidget {
  const _StarterGifShelf({this.onSelected, this.recents});
  final ValueChanged<StarterGif>? onSelected;
  final GifRecents? recents;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<StarterGif>>(
    future: bundledStarterGifs,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      final entries = snapshot.data ?? const <StarterGif>[];
      if (entries.isEmpty) {
        return const Center(
          child: Gravity(child: Text('Doorlight GIFs unavailable')),
        );
      }
      return SingleChildScrollView(
        padding: const EdgeInsets.all(8),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry
                in recents?.order(entries, (entry) => entry.hash) ?? entries)
              _StarterGifTile(
                key: ValueKey(entry.id),
                entry: entry,
                onSelected: onSelected,
              ),
          ],
        ),
      );
    },
  );
}

class _StarterGifTile extends StatefulWidget {
  const _StarterGifTile({super.key, required this.entry, this.onSelected});
  final StarterGif entry;
  final ValueChanged<StarterGif>? onSelected;
  @override
  State<_StarterGifTile> createState() => _StarterGifTileState();
}

class _StarterGifTileState extends State<_StarterGifTile> {
  late final Future<Uint8List?> _bytes = widget.entry.load();
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 112,
    child: FutureBuilder<Uint8List?>(
      future: _bytes,
      builder: (context, snapshot) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Gravity(child: BoundedGif(bytes: snapshot.data, size: 80)),
          Gravity(
            child: TextButton(
              onPressed: snapshot.data == null || widget.onSelected == null
                  ? null
                  : () => widget.onSelected!(widget.entry),
              child: Text(widget.entry.name, textAlign: TextAlign.center),
            ),
          ),
        ],
      ),
    ),
  );
}

class _ComposerGifLibrary extends StatefulWidget {
  const _ComposerGifLibrary({
    super.key,
    required this.store,
    this.onImport,
    this.onSelected,
  });
  final GifLibraryStore store;
  final VoidCallback? onImport;
  final ValueChanged<String>? onSelected;
  @override
  State<_ComposerGifLibrary> createState() => _ComposerGifLibraryState();
}

class _ComposerGifLibraryState extends State<_ComposerGifLibrary> {
  late Future<bool> _loaded = widget.store.reload();
  bool _removing = false;
  Future<void> _remove(String hash) async {
    if (_removing) return;
    setState(() => _removing = true);
    await widget.store.remove(hash);
    if (!mounted) return;
    setState(() {
      _removing = false;
      _loaded = widget.store.reload();
    });
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
    future: _loaded,
    builder: (context, snapshot) => SingleChildScrollView(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          Gravity(
            child: FilledButton.icon(
              onPressed: widget.onImport,
              icon: const Icon(Icons.add),
              label: const Text('Import GIF'),
            ),
          ),
          if (snapshot.connectionState != ConnectionState.done)
            const LinearProgressIndicator()
          else if (snapshot.data != true)
            const Gravity(child: Text('GIF library unavailable'))
          else ...[
            Gravity(
              child: Text('${widget.store.index.entries.length}/32 GIFs'),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in widget.store.recents.order(
                  widget.store.index.entries.values,
                  (entry) => entry.hash,
                ))
                  SizedBox(
                    width: 128,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Gravity(
                          child: BoundedGif(
                            path: widget.store.pathFor(entry.hash),
                            size: 100,
                          ),
                        ),
                        Gravity(
                          child: TextButton(
                            onPressed: widget.onSelected == null
                                ? null
                                : () => widget.onSelected!(entry.hash),
                            child: const Text('Use GIF'),
                          ),
                        ),
                        Gravity(
                          child: IconButton(
                            tooltip: 'Remove GIF from library',
                            onPressed: _removing
                                ? null
                                : () => _remove(entry.hash),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    ),
  );
}

/// The picker and timeline use the same bundled allowlist; no network catalog
/// or arbitrary asset path is accepted from a sticker message.
class ComposerStickers extends StatelessWidget {
  const ComposerStickers({super.key, required this.onSelected});
  final ValueChanged<BuiltInSticker> onSelected;

  @override
  Widget build(BuildContext context) => FutureBuilder<StickerManifest?>(
    future: bundledStickerManifest,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      final entries = snapshot.data?.entries;
      if (entries == null) {
        return const Center(
          child: Gravity(child: Text('Stickers unavailable')),
        );
      }
      return SingleChildScrollView(
        padding: const EdgeInsets.all(8),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in entries)
              SizedBox(
                width: 112,
                child: Gravity(
                  child: TextButton(
                    onPressed: () => onSelected(entry),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ExcludeSemantics(
                          child: StickerImage(assetId: entry.id, extent: 80),
                        ),
                        Text(entry.label, textAlign: TextAlign.center),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}
