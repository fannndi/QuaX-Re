import 'dart:io';

import 'package:extended_image/extended_image.dart';
import 'package:flutter_triple/flutter_triple.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pref/pref.dart';
import 'package:quax/downloads/downloads_model.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/library/library_model.dart';
import 'package:quax/ui/errors.dart';
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
    _queue.removeDoneListener(_listenerKey);
    _searchController.dispose();
    super.dispose();
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
      onLoading: (_) => const Center(child: CircularProgressIndicator()),
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
        _buildToolbar(context),
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
  List<LibraryEntry> _visibleEntries(List<LibraryEntry> entries) {
    final query = _query.trim().toLowerCase();
    final list = query.isEmpty
        ? List.of(entries)
        : entries.where((entry) => entry.name.toLowerCase().contains(query)).toList();

    switch (_sort) {
      case _LibrarySort.newest:
        list.sort((a, b) => b.modified.compareTo(a.modified));
      case _LibrarySort.oldest:
        list.sort((a, b) => a.modified.compareTo(b.modified));
      case _LibrarySort.name:
        list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case _LibrarySort.size:
        list.sort((a, b) => b.size.compareTo(a.size));
    }
    return list;
  }

  Widget _buildToolbar(BuildContext context) {
    final l10n = L10n.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: l10n.search,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      ),
                isDense: true,
              ),
            ),
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

  Widget _buildGrid(BuildContext context, List<LibraryEntry> entries) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(12);

    return Stack(
      children: [
        GridView.builder(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 88),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3, mainAxisSpacing: 6, crossAxisSpacing: 6),
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final entry = entries[index];
            return GestureDetector(
              onTap: () => _openEntry(entry),
              onLongPress: () => _showEntryMenu(context, entry),
              child: ClipRRect(
                borderRadius: radius,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (entry.isVideo)
                      FutureBuilder<String?>(
                        future: _model.thumbnailFor(entry),
                        builder: (context, snapshot) {
                          final thumbPath = snapshot.data;
                          if (thumbPath == null) {
                            return Container(
                                color: theme.colorScheme.surfaceContainerHighest,
                                child: const Center(child: Icon(Icons.play_circle_outline)));
                          }
                          return ExtendedImage.file(
                            File(thumbPath),
                            fit: BoxFit.cover,
                            loadStateChanged: (state) {
                              if (state.extendedImageLoadState == LoadState.failed) {
                                return const Center(child: Icon(Icons.play_circle_outline));
                              }
                              return null;
                            },
                          );
                        },
                      )
                    else
                      ExtendedImage.file(
                        entry.file,
                        fit: BoxFit.cover,
                        loadStateChanged: (state) {
                          if (state.extendedImageLoadState == LoadState.failed) {
                            return const Icon(Icons.broken_image_outlined);
                          }
                          return null;
                        },
                      ),
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
                  ],
                ),
              ),
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

  void _showEntryMenu(BuildContext context, LibraryEntry entry) {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(L10n.of(sheetContext).delete),
              onTap: () async {
                Navigator.pop(sheetContext);
                try {
                  await entry.file.delete();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(L10n.of(context).successfully_saved_the_media)));
                  }
                  await _model.refresh();
                } catch (e) {
                  if (context.mounted) {
                    showSnackBar(context, icon: '🙊', message: e.toString());
                  }
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.share),
              title: Text(L10n.of(sheetContext).share),
              onTap: () {
                Navigator.pop(sheetContext);
                SharePlus.instance.share(ShareParams(files: [XFile(entry.file.path)]));
              },
            ),
          ],
        ),
      ),
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



