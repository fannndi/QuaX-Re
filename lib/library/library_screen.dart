import 'dart:io';

import 'package:extended_image/extended_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_triple/flutter_triple.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pref/pref.dart';
import 'package:quax/downloads/downloads_model.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/library/library_model.dart';
import 'package:quax/library/library_viewer.dart';
import 'package:quax/ui/errors.dart';
import 'package:share_plus/share_plus.dart';

const MethodChannel _storageChannel = MethodChannel('browser_resolver');

/// Browses the hidden downloaded-media library. Without a configured folder it
/// offers the one-time setup (the Hentoid-style folder + .nomedia flow); with
/// one, it shows the media grid and the TikTok-style vertical viewer.
///
/// `embedInSaved: true` renders only the media grid (no app bar) so the Saved
/// screen can host it as its Downloaded tab with the shared scroll controller.
class LibraryScreen extends StatefulWidget {
  final BasePrefService prefs;
  final bool embedInSaved;

  const LibraryScreen({super.key, required this.prefs, this.embedInSaved = false});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late final LibraryModel _model = LibraryModel(widget.prefs);
  late final DownloadsModel _queue = DownloadsModel();
  late final String _listenerKey = 'LibraryScreen-${identityHashCode(this)}';
  DateTime _lastAutoRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _configureOrLoad();
    // Downloads that finish while this screen is mounted re-scan the folder
    // (debounced), so the Downloaded tab shows fresh entries without a chip
    // switch.
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
      onState: (_, entries) {
        if (!widget.embedInSaved) {
          return Scaffold(
            appBar: AppBar(
              title: Text(L10n.of(context).library),
              actions: [
                IconButton(icon: const Icon(Icons.refresh), onPressed: _configureOrLoad),
              ],
            ),
            body: _buildBody(context, entries),
          );
        }

        return _buildBody(context, entries);
      },
    );
  }

  Widget _buildBody(BuildContext context, List<LibraryEntry> entries) {
    if (!_model.isConfigured) {
      return _SetupView(onSetup: () async {
        final ok = await _model.setupLibrary();
        if (ok && mounted) await _model.refresh();
      });
    }

    final theme = Theme.of(context);
    final body = entries.isEmpty && !widget.embedInSaved
        ? (widget.embedInSaved ? const SizedBox.shrink() : Center(child: Text(L10n.of(context).library_is_empty)))
        : Stack(
            children: [
              GridView.builder(
                padding: const EdgeInsets.only(bottom: 8),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3),
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  return GestureDetector(
                    onTap: () => Navigator.push(context, MaterialPageRoute(
                        builder: (_) => LibraryViewer(model: _model, initialIndex: index))),
                    onLongPress: () => _showEntryMenu(context, entry),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (entry.isVideo)
                          FutureBuilder<String?>(
                            future: _videoThumbFor(entry),
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
                  );
                },
              ),
              if (widget.embedInSaved)
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

    // Inside the Saved screen the scroll goes through the page controller.
    return widget.embedInSaved
        ? SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: SizedBox(height: MediaQuery.of(context).size.height, child: body),
          )
        : body;
  }

  /// Cached video thumbnail via the dedicated android handler — generate once
  /// into the app's thumbs directory, reuse forever.
  Future<String?> _videoThumbFor(LibraryEntry entry) async {
    try {
      final cacheDir = Directory(p.join((await getTemporaryDirectory()).path, 'thumbs'));
      final cached = File(p.join(cacheDir.path, '${p.basenameWithoutExtension(entry.file.path)}.jpg'));
      if (await cached.exists()) {
        return cached.path;
      }

      final generated = await _storageChannel.invokeMethod<String>('videoThumbnail',
          {'path': entry.file.path, 'outPath': cached.path});
      return generated;
    } on Exception catch (_) {
      return null;
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

