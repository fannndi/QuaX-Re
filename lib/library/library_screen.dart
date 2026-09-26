import 'dart:async';
import 'dart:io';

import 'package:extended_image/extended_image.dart';
import 'package:flutter_triple/flutter_triple.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pref/pref.dart';
import 'package:quax/downloads/downloads_model.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/library/library_model.dart';
import 'package:quax/ui/errors.dart';
import 'package:quax/ui/skeletons.dart';
import 'package:share_plus/share_plus.dart';

enum _LibrarySort { newest, oldest, name, size }

/// Browses the hidden downloaded-media library — the Download tab's gallery.
/// Without a configured folder it offers the one-time setup (the Hentoid-style
/// folder + .nomedia flow); with one, it shows the searchable, sortable media
/// grid.
class LibraryScreen extends StatefulWidget {
  final BasePrefService prefs;

  const LibraryScreen({super.key, required this.prefs});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late final LibraryModel _model = LibraryModel(widget.prefs);
  late final DownloadsModel _queue = DownloadsModel();
  late final String _listenerKey = 'LibraryScreen-${identityHashCode(this)}';
  final TextEditingController _searchController = TextEditingController();
  DateTime _lastAutoRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  String _query = '';
  _LibrarySort _sort = _LibrarySort.newest;
  final Set<String> _selected = {};

  /// Typing used to re-filter and re-sort the whole library on every keystroke,
  /// inside `build()`. The query now settles first and only then reaches the
  /// cache below — a 2 000-file library stops dropping frames while typing.
  static const _searchDebounce = Duration(milliseconds: 150);
  Timer? _queryTimer;

  /// The filtered+sorted list, recomputed only when its inputs actually change
  /// (query, sort, or the folder contents). Reading it is what `build()` does
  /// now, so a rebuild for an unrelated reason — a selection tap, a progress
  /// tick — costs nothing.
  List<LibraryEntry>? _derived;
  String _derivedQuery = '';
  _LibrarySort? _derivedSort;
  List<LibraryEntry>? _derivedSource;

  bool get _selectionActive => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _configureOrLoad();
    // Downloads that finish while this screen is mounted re-scan the folder
    // (debounced), so the gallery shows fresh entries without a manual refresh.
    _queue.addDoneListener(_listenerKey, _onDownloadDone);
  }

  Future<void> _onDownloadDone() async {
    final now = DateTime.now();
    if (now.difference(_lastAutoRefresh).inMilliseconds < 1500) {
      return;
    }
    _lastAutoRefresh = now;
    await _model.refresh();
  }

  @override
  void dispose() {
    _queryTimer?.cancel();
    _queue.removeDoneListener(_listenerKey);
    _searchController.dispose();
    _model.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _queryTimer?.cancel();
    _queryTimer = Timer(_searchDebounce, () {
      if (mounted) setState(() => _query = value);
    });
  }

  Future<void> _configureOrLoad() async {
    if (!_model.isConfigured || !await Directory(_model.libraryPath).exists()) {
      await _attemptSetup();
      return;
    }
    await _model.refresh();
  }

  /// Runs the folder setup with the storage-permission safety net: when
  /// Android refuses a plain write (an SD card without all-files-access), the
  /// system screen was opened — explain, then retry right away upon return.
  Future<void> _attemptSetup() async {
    final error = ValueNotifier<String?>(null);
    final ok = await _model.setupLibrary(error: error);
    if (ok && mounted) {
      await _model.refresh();
      return;
    }
    if (!mounted) return;

    if (error.value == 'storage_permission_needed') {
      final retry = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(L10n.of(context).library_setup_title),
          content: Text(L10n.of(dialogContext).library_storage_permission_needed),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(L10n.of(dialogContext).retry)),
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(L10n.of(dialogContext).close)),
          ],
        ),
      );

      if (retry == true && mounted) {
        // Back from Android's all-files-access screen: try to finish the setup.
        return _attemptSetup();
      }
      return;
    }

    if (error.value != null) {
      showSnackBar(context, icon: '🙊', message: error.value!);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScopedBuilder<LibraryModel, List<LibraryEntry>>.transition(
      store: _model,
      onError: (_, e) => ScaffoldErrorWidget(
        prefix: L10n.current.unable_to_load_the_tweets,
        error: e,
        stackTrace: null,
        onRetry: _configureOrLoad,
        retryText: L10n.current.retry,
      ),
      // Tiles arriving read as content loading; a lone spinner makes the same
      // wait feel longer than it is.
      onLoading: (_) => const MediaGridSkeleton(columns: 3, rows: 5),
      onState: (_, entries) => _buildBody(context, entries),
    );
  }

  Widget _buildBody(BuildContext context, List<LibraryEntry> entries) {
    if (!_model.isConfigured) {
      return _SetupView(onSetup: () async {
        final ok = await _model.setupLibrary();
        if (ok && mounted) await _model.refresh();
      });
    }

    final visible = _visibleEntries(entries);

    return Column(
      children: [
        _buildToolbar(context, visible),
        Expanded(
          child: entries.isEmpty
              ? Center(child: Text(L10n.of(context).library_is_empty))
              : visible.isEmpty
                  ? Center(child: Text(L10n.of(context).library_is_empty))
                  : _buildGrid(context, visible),
        ),
      ],
    );
  }

  /// Search by file name plus the sort menu (newest/oldest/name/size).
  ///
  /// Memoized on (query, sort, entries): `build()` calls this, and rebuilding
  /// for a selection tap used to redo the whole filter+sort every time.
  List<LibraryEntry> _visibleEntries(List<LibraryEntry> entries) {
    if (identical(entries, _derivedSource) && _query == _derivedQuery && _sort == _derivedSort) {
      final cached = _derived;
      if (cached != null) return cached;
    }

    final query = _query.trim().toLowerCase();
    // [LibraryEntry.nameLower] is folded once at construction, so neither the
    // filter nor the name sort re-folds thousands of strings per keystroke.
    final list = query.isEmpty
        ? List.of(entries)
        : entries.where((entry) => entry.nameLower.contains(query)).toList();

    switch (_sort) {
      case _LibrarySort.newest:
        list.sort((a, b) => b.modified.compareTo(a.modified));
      case _LibrarySort.oldest:
        list.sort((a, b) => a.modified.compareTo(b.modified));
      case _LibrarySort.name:
        list.sort((a, b) => a.nameLower.compareTo(b.nameLower));
      case _LibrarySort.size:
        list.sort((a, b) => b.size.compareTo(a.size));
    }

    _derived = list;
    _derivedSource = entries;
    _derivedQuery = _query;
    _derivedSort = _sort;
    return list;
  }

  Widget _buildToolbar(BuildContext context, List<LibraryEntry> entries) {
    if (_selectionActive) return _buildSelectionBar(context, entries);

    final l10n = L10n.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              onChanged: _onQueryChanged,
              decoration: InputDecoration(
                hintText: l10n.search,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _queryTimer?.cancel();
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      ),
                isDense: true,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: l10n.refresh,
            onPressed: _configureOrLoad,
          ),
          PopupMenuButton<_LibrarySort>(
            icon: const Icon(Icons.sort),
            tooltip: l10n.sort,
            initialValue: _sort,
            onSelected: (value) => setState(() => _sort = value),
            itemBuilder: (context) => [
              PopupMenuItem(value: _LibrarySort.newest, child: Text(l10n.newest)),
              PopupMenuItem(value: _LibrarySort.oldest, child: Text(l10n.oldest)),
              PopupMenuItem(value: _LibrarySort.name, child: Text(l10n.name)),
              PopupMenuItem(value: _LibrarySort.size, child: Text(l10n.size)),
            ],
          ),
        ],
      ),
    );
  }

  /// Replaces the toolbar while files are selected: count, select-all, share
  /// and delete for the whole selection.
  Widget _buildSelectionBar(BuildContext context, List<LibraryEntry> entries) {
    final l10n = L10n.of(context);
    final allSelected = entries.isNotEmpty && _selected.length == entries.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: l10n.close,
            onPressed: () => setState(_selected.clear),
          ),
          Expanded(
            child: Text('${_selected.length}', style: Theme.of(context).textTheme.titleMedium),
          ),
          IconButton(
            icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
            tooltip: l10n.select_all,
            onPressed: () => setState(() {
              if (allSelected) {
                _selected.clear();
              } else {
                _selected
                  ..clear()
                  ..addAll(entries.map((entry) => entry.file.path));
              }
            }),
          ),
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: l10n.share,
            onPressed: _shareSelected,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: l10n.delete,
            onPressed: _deleteSelected,
          ),
        ],
      ),
    );
  }

  void _toggleSelection(LibraryEntry entry) {
    setState(() {
      if (!_selected.remove(entry.file.path)) {
        _selected.add(entry.file.path);
      }
    });
  }

  Future<void> _shareSelected() async {
    final files = _selected.map((path) => XFile(path)).toList();
    if (files.isEmpty) return;
    await SharePlus.instance.share(ShareParams(files: files));
  }

  Future<void> _deleteSelected() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(L10n.of(dialogContext).are_you_sure),
        content: Text(L10n.of(dialogContext).delete_selected_media),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(L10n.of(dialogContext).cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(L10n.of(dialogContext).delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    for (final path in _selected) {
      try {
        await File(path).delete();
      } catch (_) {
        // Already gone: the refresh below settles the list either way.
      }
    }
    // Deleted files must not keep serving a cached thumbnail path.
    _model.forgetThumbnails();
    setState(_selected.clear);
    await _model.refresh();
  }

  Widget _buildGrid(BuildContext context, List<LibraryEntry> entries) {
    return Stack(
      children: [
        // `.maxCrossAxisExtent` instead of a fixed column count: the tiles keep
        // a sane size on tablets and in landscape, and the aspect ratio leaves
        // room for the filename strip that used to be cropped away.
        GridView.builder(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 88),
          cacheExtent: 400,
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 140,
            childAspectRatio: 0.78,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
          ),
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final entry = entries[index];
            return LibraryTile(
              key: ValueKey(entry.file.path),
              entry: entry,
              // Only the tapped tile's selection changes, so the delegate reads
              // the flag from the parent set at build time.
              selected: _selected.contains(entry.file.path),
              thumbnailFor: _model.thumbnailFor,
              onTap: () => _selectionActive ? _toggleSelection(entry) : _openEntry(entry),
              onLongPress: () => _toggleSelection(entry),
            );
          },
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton.extended(
            onPressed: _importExisting,
            icon: const Icon(Icons.folder_copy_outlined),
            label: Text(L10n.of(context).library_import_existing),
          ),
        ),
      ],
    );
  }

  Future<void> _openEntry(LibraryEntry entry) async {
    final ok = await _model.openExternally(entry.file.path);
    if (!ok && mounted) {
      showSnackBar(context, icon: '🙊', message: L10n.of(context).oops_something_went_wrong);
    }
  }

  Future<void> _importExisting() async {
    final ok = await _model.importExisting();
    if (!mounted || !ok) return;
    await _model.refresh();
  }
}

/// A single media tile.
///
/// Extracted from the grid's `itemBuilder` so it can be wrapped in a
/// [RepaintBoundary]: toggling one tile's selection repaints that tile instead
/// of the whole grid. [thumbnailFor] is the model's cached Future lookup, so a
/// rebuild never re-probes the filesystem or flashes the placeholder.
class LibraryTile extends StatelessWidget {
  final LibraryEntry entry;
  final bool selected;
  final Future<String?> Function(LibraryEntry) thumbnailFor;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const LibraryTile({
    super.key,
    required this.entry,
    required this.selected,
    required this.thumbnailFor,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return RepaintBoundary(
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (entry.isVideo) _buildVideoThumbnail(context) else _buildImage(context),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: Colors.black38,
                  padding: const EdgeInsets.all(4),
                  child: Text(entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(color: Colors.white)),
                ),
              ),
              // Fade, not a hard colour swap: opacity-only changes stay on the
              // compositor and never re-run layout for the tile.
              AnimatedOpacity(
                opacity: selected ? 1 : 0,
                duration: const Duration(milliseconds: 120),
                child: IgnorePointer(
                  child: ColoredBox(color: theme.colorScheme.primary.withValues(alpha: 0.35)),
                ),
              ),
              AnimatedOpacity(
                opacity: selected ? 1 : 0,
                duration: const Duration(milliseconds: 120),
                child: Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.check_circle,
                        size: 20, color: theme.colorScheme.primary),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Decoding is capped to roughly the tile's on-screen size: a 4K video frame
  /// is ~33 MB as a full bitmap, and the grid only ever shows ~140 px of it.
  int _decodeWidth(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return (140 * dpr).round();
  }

  Widget _buildVideoThumbnail(BuildContext context) {
    final theme = Theme.of(context);

    return FutureBuilder<String?>(
      // A stable Future from the model's cache, not one built in `build()`.
      future: thumbnailFor(entry),
      builder: (context, snapshot) {
        final thumbPath = snapshot.data;
        if (thumbPath == null) {
          return ColoredBox(
            color: theme.colorScheme.surfaceContainerHighest,
            child: const Center(child: Icon(Icons.play_circle_outline)),
          );
        }
        return ExtendedImage.file(
          File(thumbPath),
          fit: BoxFit.cover,
          cacheWidth: _decodeWidth(context),
          loadStateChanged: (state) {
            if (state.extendedImageLoadState == LoadState.failed) {
              return const Center(child: Icon(Icons.play_circle_outline));
            }
            return null;
          },
        );
      },
    );
  }

  Widget _buildImage(BuildContext context) {
    return ExtendedImage.file(
      entry.file,
      fit: BoxFit.cover,
      cacheWidth: _decodeWidth(context),
      loadStateChanged: (state) {
        if (state.extendedImageLoadState == LoadState.failed) {
          return const Icon(Icons.broken_image_outlined);
        }
        return null;
      },
    );
  }
}

/// One-time setup, shown when Library opens without a folder yet — same intent
/// as Hentoid's onboarding: pick where downloaded media lives (hidden from the
/// gallery with a .nomedia marker).
class _SetupView extends StatelessWidget {
  final VoidCallback onSetup;

  const _SetupView({required this.onSetup});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.video_library_outlined, size: 48),
            const SizedBox(height: 16),
            Text(L10n.of(context).library_setup_title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(L10n.of(context).library_setup_description, textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onSetup,
              icon: const Icon(Icons.folder_open),
              label: Text(L10n.of(context).library_setup_pick),
            ),
          ],
        ),
      ),
    );
  }
}




