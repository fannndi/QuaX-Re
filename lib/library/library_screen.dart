import 'dart:io';

import 'package:extended_image/extended_image.dart';
import 'package:flutter_triple/flutter_triple.dart';
import 'package:material_ui/material_ui.dart';
import 'package:better_player_plus/better_player_plus.dart';
import 'package:pref/pref.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/library/library_model.dart';
import 'package:quax/library/library_viewer.dart';
import 'package:quax/ui/errors.dart';

/// Browses the hidden downloaded-media library. Without a configured folder it
/// offers the one-time setup (the Hentoid-style folder + .nomedia flow); with
/// one, it shows the media grid and the TikTok-style vertical viewer.
class LibraryScreen extends StatefulWidget {
  final BasePrefService prefs;

  const LibraryScreen({super.key, required this.prefs});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late final LibraryModel _model = LibraryModel(widget.prefs);

  @override
  void initState() {
    super.initState();
    _configureOrLoad();
  }

  Future<void> _configureOrLoad() async {
    if (!_model.isConfigured || !await Directory(_model.libraryPath).exists()) {
      await _model.setupLibrary();
    }
    await _model.refresh();
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
        if (!_model.isConfigured) {
          return _SetupView(onSetup: () async {
            final ok = await _model.setupLibrary();
            if (ok && context.mounted) await _configureOrLoad();
          });
        }

        final theme = Theme.of(context);
        return Scaffold(
          appBar: AppBar(
            title: Text(L10n.of(context).library),
            actions: [
              IconButton(icon: const Icon(Icons.refresh), onPressed: _configureOrLoad),
            ],
          ),
          body: entries.isEmpty
              ? Center(child: Text(L10n.of(context).library_is_empty))
              : GridView.builder(
                  padding: const EdgeInsets.only(bottom: 8),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return GestureDetector(
                      onTap: () => Navigator.push(context, MaterialPageRoute(
                          builder: (_) => LibraryViewer(model: _model, initialIndex: index))),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (entry.isVideo)
                            Container(color: theme.colorScheme.surfaceContainerHighest,
                                child: const Center(child: Icon(Icons.play_circle_outline)))
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
        );
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
