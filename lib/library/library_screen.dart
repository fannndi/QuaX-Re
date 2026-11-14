import 'dart:async';
import 'dart:io';

import 'package:extended_image/extended_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_triple/flutter_triple.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pref/pref.dart';
import 'package:quax/constants.dart';
import 'package:quax/downloads/downloads_model.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/library/library_model.dart';
import 'package:quax/library/library_storage_sheet.dart';
import 'package:quax/ui/dates.dart';
import 'package:quax/ui/errors.dart';
import 'package:quax/utils/image_decode.dart';
import 'package:quax/utils/storage_report.dart';
import 'package:share_plus/share_plus.dart';

enum _LibrarySort { newest, oldest, name, size }

enum _LibraryFilter { all, photos, videos }

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

class _LibraryScreenState extends State<LibraryScreen> with AutomaticKeepAliveClientMixin<LibraryScreen> {
  late final LibraryModel _model = LibraryModel(widget.prefs);
  late final DownloadsModel _queue = DownloadsModel();
  late final String _listenerKey = 'LibraryScreen-${identityHashCode(this)}';
  final TextEditingController _searchController = TextEditingController();
  Timer? _refreshTimer;
  String _query = '';
  _LibrarySort _sort = _LibrarySort.newest;
  _LibraryFilter _filter = _LibraryFilter.all;
  final Set<String> _selected = {};
  List<LibraryVolume> _volumes = const [];
  LibraryVolume? _volume;
  bool _missing = false;
  bool _importing = false;

  bool get _selectionActive => _selected.isNotEmpty;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _sort = _sortFromName(widget.prefs.get<String>(optionLibrarySort));
    _filter = _filterFromName(widget.prefs.get<String>(optionLibraryFilter));
    _configureOrLoad();
    // Downloads that finish while this screen is mounted re-scan the folder
    // after the batch settles, so the gallery shows fresh entries without a
    // manual refresh. A leading throttle used to drop the last event of a
    // batch, leaving the newest download invisible.
    _queue.addDoneListener(_listenerKey, _onDownloadDone);
  }

  static _LibrarySort _sortFromName(String? name) => _LibrarySort.values
      .firstWhere((sort) => sort.name == name, orElse: () => _LibrarySort.newest);

  static _LibraryFilter _filterFromName(String? name) => _LibraryFilter.values
      .firstWhere((filter) => filter.name == name, orElse: () => _LibraryFilter.all);

  void _onDownloadDone() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) _model.refresh();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _queue.removeDoneListener(_listenerKey);
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _configureOrLoad() async {
    if (!_model.isConfigured) {
      if (mounted) setState(() => _missing = false);
      await _loadVolumes();
      return;
    }
    if (!await Directory(_model.libraryPath).exists()) {
      if (mounted) setState(() => _missing = true);
      return;
    }
    if (mounted && _missing) setState(() => _missing = false);
    await _model.refresh();
  }

  Future<void> _loadVolumes() async {
    try {
      final volumes = await _model.availableVolumes();
      if (!mounted) return;
      setState(() {
        _volumes = volumes;
        _volume = volumes.firstOrNull;
      });
    } on Exception {
      // The setup view keeps the folder picker as the fallback.
    }
  }

  Future<void> _useHidden() async {
    if (_volumes.isEmpty) await _loadVolumes();
    if (!mounted) return;

    final volume = await pickLibraryVolume(context, _volumes);
    if (volume == null) {
      if (mounted && _volumes.isEmpty) {
        showSnackBar(context,
            icon: '🙊', message: L10n.of(context).library_storage_unavailable_body);
      }
      return;
    }
    if (!mounted) return;

    final error = ValueNotifier<String?>(null);
    final ok = await _model.setupHiddenLibrary(volume, error: error);
    if (!mounted) return;

    if (ok) {
      if (mounted) setState(() => _missing = false);
      await _model.refresh();
      return;
    }
    if (error.value == 'storage_permission_needed') {
      showSnackBar(context,
          icon: '🔒', message: L10n.of(context).library_storage_permission_needed);
    } else if (error.value != null) {
      showSnackBar(context, icon: '🙊', message: error.value!);
    }
  }

  Future<void> _manageStorage() async {
    final changed = await showLibraryStorageSheet(context, widget.prefs);
    if (!mounted) return;
    if (changed == true) {
      await _model.refresh();
      if (mounted) setState(() => _missing = false);
    } else {
      await _configureOrLoad();
    }
  }

  /// Runs the folder setup with the storage-permission safety net: when
  /// Android refuses a plain write (an SD card without all-files-access), the
  /// system screen was opened — explain, then retry right away upon return.
  Future<void> _attemptSetup() async {
    final error = ValueNotifier<String?>(null);
    final ok = await _model.setupLibrary(error: error);
    if (ok && mounted) {
      setState(() => _missing = false);
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
    super.build(context);
    if (!_model.isConfigured) return _buildSetup(context);
    if (_missing) return _buildMissing(context);
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

  Widget _buildSetup(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Icon(Icons.video_library_outlined, size: 48, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text(l10n.library_setup_title,
            textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(l10n.library_setup_description, textAlign: TextAlign.center),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.shield_outlined),
                  title: Text(l10n.library_storage_hidden),
                  subtitle: Text(l10n.library_storage_hidden_description),
                ),
                if (_volumes.isEmpty)
                  Text(l10n.library_storage_unavailable_body,
                      style: TextStyle(color: theme.colorScheme.error))
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final volume in _volumes)
                        ChoiceChip(
                          avatar: Icon(volume.isPrimary ? Icons.phone_android : Icons.sd_card_outlined),
                          label: Text(libraryVolumeLabel(l10n, volume)),
                          selected: _volume == volume,
                          onSelected: (_) => setState(() => _volume = volume),
                        ),
                    ],
                  ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _volume == null ? null : _useHidden,
                  icon: const Icon(Icons.lock_outline),
                  label: Text(l10n.library_storage_use_hidden),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(l10n.library_storage_visible),
                  subtitle: Text(l10n.library_storage_visible_description),
                ),
                OutlinedButton.icon(
                  onPressed: _attemptSetup,
                  icon: const Icon(Icons.folder_open),
                  label: Text(l10n.library_setup_pick),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMissing(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sd_card_alert_outlined, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(l10n.library_storage_unavailable, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(l10n.library_storage_unavailable_body, textAlign: TextAlign.center),
            const SizedBox(height: 24),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(onPressed: _configureOrLoad, child: Text(l10n.retry)),
                OutlinedButton(onPressed: _manageStorage, child: Text(l10n.library_storage_change)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, List<LibraryEntry> entries) {
    final visible = _visibleEntries(entries);

    return Column(
      children: [
        if (_importing) const LinearProgressIndicator(minHeight: 2),
        _buildToolbar(context, entries, visible),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _configureOrLoad,
            child: entries.isEmpty
                ? _buildEmptyLibrary(context)
                : visible.isEmpty
                    ? _buildNoResults(context)
                    : _buildGrid(context, visible),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyLibrary(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 48),
        Icon(Icons.collections_outlined, size: 48, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text(l10n.library_is_empty, textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          _model.isHidden ? l10n.library_empty_hidden_body : l10n.library_empty_visible_body,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Center(
          child: FilledButton.icon(
            onPressed: _importExisting,
            icon: const Icon(Icons.folder_copy_outlined),
            label: Text(l10n.library_import_existing),
          ),
        ),
      ],
    );
  }

  Widget _buildNoResults(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 48),
        Icon(Icons.search_off, size: 48, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text(l10n.library_no_results, textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
        const SizedBox(height: 24),
        Center(
          child: OutlinedButton(
            onPressed: _clearFilters,
            child: Text(l10n.library_clear_search),
          ),
        ),
      ],
    );
  }

  /// Search by file name, the photo/video filter, and the sort menu.
  List<LibraryEntry> _visibleEntries(List<LibraryEntry> entries) {
    final query = _query.trim().toLowerCase();
    final list = entries.where((entry) {
      if (_filter == _LibraryFilter.photos && entry.isVideo) return false;
      if (_filter == _LibraryFilter.videos && !entry.isVideo) return false;
      return query.isEmpty || entry.name.toLowerCase().contains(query);
    }).toList();

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

  void _setQuery(String value) {
    setState(() {
      _query = value;
      _pruneSelection();
    });
  }

  void _setFilter(_LibraryFilter filter) {
    setState(() {
      _filter = filter;
      _pruneSelection();
    });
    widget.prefs.set<String>(optionLibraryFilter, filter.name);
  }

  void _setSort(_LibrarySort sort) {
    setState(() => _sort = sort);
    widget.prefs.set<String>(optionLibrarySort, sort.name);
  }

  void _clearFilters() {
    _searchController.clear();
    setState(() {
      _query = '';
      _filter = _LibraryFilter.all;
    });
    widget.prefs.set<String>(optionLibraryFilter, _LibraryFilter.all.name);
  }

  /// A selected file hidden by the new filter cannot be shared or deleted by
  /// the toolbar the reader is looking at; drop it instead of acting on it
  /// invisibly.
  void _pruneSelection() {
    final visible = _visibleEntries(_model.state).map((entry) => entry.file.path).toSet();
    _selected.retainWhere(visible.contains);
  }

  Widget _buildToolbar(
      BuildContext context, List<LibraryEntry> entries, List<LibraryEntry> visible) {
    if (_selectionActive) return _buildSelectionBar(context);

    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final photos = entries.where((entry) => !entry.isVideo).length;
    final videos = entries.length - photos;
    final bytes = visible.fold<int>(0, (sum, entry) => sum + entry.size);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  onChanged: _setQuery,
                  decoration: InputDecoration(
                    hintText: l10n.search,
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close),
                            tooltip: l10n.close,
                            onPressed: () {
                              _searchController.clear();
                              _setQuery('');
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
                onSelected: _setSort,
                itemBuilder: (context) => [
                  PopupMenuItem(value: _LibrarySort.newest, child: Text(l10n.newest)),
                  PopupMenuItem(value: _LibrarySort.oldest, child: Text(l10n.oldest)),
                  PopupMenuItem(value: _LibrarySort.name, child: Text(l10n.name)),
                  PopupMenuItem(value: _LibrarySort.size, child: Text(l10n.size)),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _filterChip(l10n.library_filter_all, entries.length, _LibraryFilter.all),
              _filterChip(l10n.library_filter_photos, photos, _LibraryFilter.photos),
              _filterChip(l10n.library_filter_videos, videos, _LibraryFilter.videos),
              Text(
                l10n.library_stats(visible.length, formatBytes(bytes)),
                style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _filterChip(String label, int count, _LibraryFilter filter) {
    return FilterChip(
      label: Text('$label $count'),
      selected: _filter == filter,
      onSelected: (_) => _setFilter(filter),
    );
  }

  /// Replaces the toolbar while files are selected: count, select-all, info,
  /// export, share and delete for the whole selection.
  Widget _buildSelectionBar(BuildContext context) {
    final l10n = L10n.of(context);
    final visible = _visibleEntries(_model.state);
    final allSelected = visible.isNotEmpty && _selected.length == visible.length;

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
                  ..addAll(visible.map((entry) => entry.file.path));
              }
            }),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: l10n.library_more_actions,
            onSelected: (value) {
              if (value == 'info') _showInfoSelected();
              if (value == 'export') _exportSelected();
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'info',
                enabled: _selected.length == 1,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.info_outline),
                  title: Text(l10n.library_file_info),
                ),
              ),
              PopupMenuItem(
                value: 'export',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.ios_share),
                  title: Text(l10n.library_export_selected),
                ),
              ),
            ],
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

    final entries = _model.state.where((entry) => _selected.contains(entry.file.path)).toList();
    for (final entry in entries) {
      await _model.deleteEntry(entry);
    }
    setState(_selected.clear);
    await _model.refresh();
  }

  Future<void> _exportSelected() async {
    final entries = _model.state.where((entry) => _selected.contains(entry.file.path)).toList();
    if (entries.isEmpty) return;

    final l10n = L10n.of(context);
    final picked = await FilePicker.getDirectoryPath();
    if (picked == null || !mounted) return;
    if (!await _model.ensureStorageAccess()) {
      if (mounted) {
        showSnackBar(context,
            icon: '🔒', message: L10n.of(context).library_storage_permission_needed);
      }
      return;
    }

    final result = await _model.exportTo(picked, entries: entries);
    if (!mounted) return;
    setState(_selected.clear);

    if (result.error == 'no_space') {
      showSnackBar(context, icon: '🙊', message: l10n.library_export_no_space);
    } else if (result.error == 'inside_library') {
      showSnackBar(context, icon: '🙊', message: l10n.library_export_inside);
    } else if (result.error != null) {
      showSnackBar(context, icon: '🙊', message: l10n.library_move_failed);
    } else if (result.failed > 0) {
      showSnackBar(context,
          icon: '⚠️', message: l10n.library_export_partial(result.copied, result.failed));
    } else {
      showSnackBar(context,
          icon: '✅', message: l10n.library_export_done(result.copied, result.path!));
    }
  }

  void _showInfoSelected() {
    final entry = _model.state.where((entry) => _selected.contains(entry.file.path)).firstOrNull;
    if (entry != null) _showInfo(entry);
  }

  Future<void> _showInfo(LibraryEntry entry) async {
    final l10n = L10n.of(context);
    final hidden = _model.isHidden;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(entry.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium),
                const SizedBox(height: 12),
                _infoRow(sheetContext, l10n.size, formatBytes(entry.size)),
                _infoRow(sheetContext, l10n.library_type,
                    entry.isVideo ? l10n.library_filter_videos : l10n.library_filter_photos),
                _infoRow(sheetContext, l10n.library_date,
                    absoluteDateFormat.format(entry.modified.toLocal())),
                _infoRow(sheetContext, l10n.library,
                    hidden ? l10n.library_storage_hidden : l10n.library_storage_visible),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          _openEntry(entry);
                        },
                        icon: const Icon(Icons.open_in_new),
                        label: Text(l10n.library_open_with),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          _shareEntry(entry);
                        },
                        icon: const Icon(Icons.share),
                        label: Text(l10n.share),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _infoRow(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }

  Widget _buildGrid(BuildContext context, List<LibraryEntry> entries) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(12);
    // The same column preference the profile media grid honours: a reader who
    // sets five columns there should not get three in the library.
    final columns = PrefService.of(context, listen: false).get<int>(optionMediaGridColumns) ?? 3;
    // Three columns of downloaded media: a 4000px photo decoded whole for a
    // ~120pt tile is ~48MB of bitmap the tile cannot show, and the gallery can
    // hold thousands of files. Same treatment the search grid already gives it.
    final decodeWidth =
        decodeWidthFor(context, MediaQuery.sizeOf(context).width / columns, maxWidth: 1080);

    return Stack(
      children: [
        GridView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 88),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns, mainAxisSpacing: 6, crossAxisSpacing: 6),
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final entry = entries[index];
            final selected = _selected.contains(entry.file.path);
            final preview = entry.isVideo
                ? FutureBuilder<String?>(
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
                        cacheWidth: decodeWidth,
                        loadStateChanged: (state) {
                          if (state.extendedImageLoadState == LoadState.failed) {
                            return const Center(child: Icon(Icons.play_circle_outline));
                          }
                          return null;
                        },
                      );
                    },
                  )
                : ExtendedImage.file(
                    entry.file,
                    fit: BoxFit.cover,
                    cacheWidth: decodeWidth,
                    loadStateChanged: (state) {
                      if (state.extendedImageLoadState == LoadState.failed) {
                        return const Icon(Icons.broken_image_outlined);
                      }
                      return null;
                    },
                  );

            return Semantics(
              label: entry.name,
              button: true,
              child: GestureDetector(
                onTap: () => _selectionActive ? _toggleSelection(entry) : _openEntry(entry),
                onLongPress: () => _toggleSelection(entry),
                child: ClipRRect(
                  borderRadius: radius,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // The filename used to cover every tile; real files are
                      // hashed media names, and the reader recognises a photo
                      // by the photo. The info sheet still spells it out.
                      preview,
                      if (entry.isVideo)
                        Positioned(
                          right: 6,
                          bottom: 6,
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.play_arrow, size: 16, color: Colors.white),
                          ),
                        ),
                      if (selected)
                        Positioned.fill(
                          child: ColoredBox(
                              color: theme.colorScheme.primary.withValues(alpha: 0.35)),
                        ),
                      if (selected)
                        Positioned(
                          top: 4,
                          right: 4,
                          child: Icon(Icons.check_circle, color: theme.colorScheme.primary),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton.extended(
            onPressed: _importing ? null : _importExisting,
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

  Future<void> _shareEntry(LibraryEntry entry) async {
    await SharePlus.instance.share(ShareParams(files: [XFile(entry.file.path)]));
  }

  Future<void> _importExisting() async {
    if (_importing) return;
    final l10n = L10n.of(context);
    if (!await _model.ensureStorageAccess()) {
      if (mounted) {
        showSnackBar(context,
            icon: '🔒', message: L10n.of(context).library_storage_permission_needed);
      }
      return;
    }
    final source = await FilePicker.getDirectoryPath();
    if (source == null || !mounted) return;

    final count = await _model.countImportableIn(source);
    if (!mounted) return;
    if (count == 0) {
      showSnackBar(context, icon: '🙊', message: l10n.library_no_media_found);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(L10n.of(dialogContext).library_import_title),
        content: Text(L10n.of(dialogContext).library_import_count(count)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(L10n.of(dialogContext).cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(L10n.of(dialogContext).library_import_existing),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _importing = true);
    final ok = await _model.importFromDirectory(source);
    if (!mounted) return;
    setState(() => _importing = false);

    if (!ok) {
      showSnackBar(context, icon: '⚠️', message: l10n.library_import_failed);
      return;
    }
    await _model.refresh();
  }
}




