import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:pref/pref.dart';
import 'package:quax/downloads/downloads_model.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/library/library_model.dart';
import 'package:quax/ui/errors.dart';
import 'package:quax/utils/downloads.dart';
import 'package:quax/utils/storage_report.dart';

/// Opens the storage settings for the library: hidden app-private storage on
/// the internal volume or an SD card, or a visible folder with `.nomedia`.
///
/// Resolves to true when the library was moved or reconfigured, so the caller
/// can rebuild the gallery.
Future<bool?> showLibraryStorageSheet(BuildContext context, BasePrefService prefs) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _LibraryStorageSheet(prefs: prefs),
  );
}

String libraryVolumeLabel(L10n l10n, LibraryVolume volume) =>
    volume.isPrimary ? l10n.library_volume_internal : l10n.library_volume_sd;

/// Asks which volume the hidden library should live on. One volume is not a
/// choice, so it is returned without a dialog.
Future<LibraryVolume?> pickLibraryVolume(
    BuildContext context, List<LibraryVolume> volumes) async {
  if (volumes.isEmpty) return null;
  if (volumes.length == 1) return volumes.first;

  final l10n = L10n.of(context);
  return showDialog<LibraryVolume>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: Text(l10n.library_storage_volume),
      children: [
        for (final volume in volumes)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, volume),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(volume.isPrimary ? Icons.phone_android : Icons.sd_card_outlined),
              title: Text(libraryVolumeLabel(l10n, volume)),
              subtitle: Text(
                volume.isPrimary
                    ? l10n.library_volume_internal_description
                    : l10n.library_volume_sd_description,
              ),
            ),
          ),
      ],
    ),
  );
}

class _LibraryStorageSheet extends StatefulWidget {
  final BasePrefService prefs;

  const _LibraryStorageSheet({required this.prefs});

  @override
  State<_LibraryStorageSheet> createState() => _LibraryStorageSheetState();
}

class _LibraryStorageSheetState extends State<_LibraryStorageSheet> {
  late final LibraryModel _model = LibraryModel(widget.prefs);
  late final DownloadsModel _queue = DownloadsModel();

  late LibraryStorageMode _mode = _model.storageMode;
  List<LibraryVolume> _volumes = const [];
  LibraryVolume? _selectedVolume;
  String? _visibleParent;
  bool _galleryVisible = false;
  bool _busy = false;
  bool _loading = true;
  int _count = 0;
  int _bytes = 0;

  @override
  void initState() {
    super.initState();
    _galleryVisible = _model.galleryVisible;
    _load();
  }

  Future<void> _load() async {
    List<LibraryVolume> volumes = const [];
    try {
      volumes = await _model.availableVolumes();
    } on Exception {
      // The visible-folder option still works without volume enumeration.
    }
    await _model.refresh();
    if (!mounted) return;

    final currentVolume = volumes
        .where((volume) =>
            p.isWithin(volume.volumeRoot, _model.libraryPath) ||
            p.equals(volume.hiddenRoot, _model.libraryPath))
        .firstOrNull;
    setState(() {
      _volumes = volumes;
      _selectedVolume = currentVolume ?? volumes.firstOrNull;
      if (!_model.isHidden && _model.libraryPath.isNotEmpty) {
        _visibleParent = p.dirname(_model.libraryPath);
      }
      _count = _model.state.length;
      _bytes = _model.state.fold<int>(0, (sum, entry) => sum + entry.size);
      _loading = false;
    });
  }

  bool get _canApply {
    if (_busy || _loading) return false;
    if (_mode == LibraryStorageMode.hidden) {
      final volume = _selectedVolume;
      if (volume == null) return false;
      return !(_model.isHidden && p.equals(_model.libraryPath, volume.hiddenRoot));
    }
    final parent = _visibleParent;
    if (parent == null) return false;
    return !(!_model.isHidden && p.equals(_model.libraryPath, p.join(parent, libraryFolderName)));
  }

  Future<void> _pickVisible() async {
    final picked = await FilePicker.getDirectoryPath();
    if (picked != null && mounted) setState(() => _visibleParent = picked);
  }

  Future<void> _apply() async {
    if (!_canApply) return;

    final target = _mode == LibraryStorageMode.hidden
        ? libraryVolumeLabel(L10n.of(context), _selectedVolume!)
        : p.join(_visibleParent!, libraryFolderName);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(L10n.of(dialogContext).library_move_confirm_title),
        content: Text(L10n.of(dialogContext).library_move_confirm_body(_count, target)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(L10n.of(dialogContext).cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(L10n.of(dialogContext).library_storage_apply),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    if (_mode == LibraryStorageMode.visible && !await _model.ensureStorageAccess()) {
      if (mounted) {
        showSnackBar(context,
            icon: '🔒', message: L10n.of(context).library_storage_permission_needed);
      }
      return;
    }

    setState(() => _busy = true);
    // A transfer that lands during the move would save into the folder being
    // emptied. Hold the queue, move, then bring back exactly what was active.
    final active = _queue.state
        .where((item) =>
            item.status == DownloadStatus.queued || item.status == DownloadStatus.running)
        .map((item) => item.fileName)
        .toList();
    final oldPath = _model.libraryPath;
    _queue.pauseAll();

    final result = _mode == LibraryStorageMode.hidden
        ? await _model.moveToHidden(_selectedVolume!)
        : await _model.moveToVisibleAt(_visibleParent!);

    if (result.error == null) {
      _queue.relocateSavedPaths(oldPath, _model.libraryPath);
    }

    for (final name in active) {
      final item = _queue.itemFor(name);
      if (item != null) resumeDownload(item, prefs: widget.prefs);
    }

    if (!mounted) return;
    setState(() => _busy = false);

    final l10n = L10n.of(context);
    if (result.error == 'inside_library') {
      showSnackBar(context, icon: '🙊', message: l10n.library_export_inside);
      return;
    }
    if (result.error == 'no_space') {
      showSnackBar(context, icon: '🙊', message: l10n.library_move_no_space);
      return;
    }
    if (result.error != null) {
      showSnackBar(context, icon: '🙊', message: l10n.library_move_failed);
      return;
    }
    if (result.failed > 0) {
      showSnackBar(context,
          icon: '⚠️', message: l10n.library_move_partial(result.moved, result.failed));
    } else {
      showSnackBar(context, icon: '📁', message: l10n.library_move_done(result.moved));
    }
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _export() async {
    if (_busy || _loading) return;
    final l10n = L10n.of(context);
    if (_model.state.isEmpty) {
      showSnackBar(context, icon: '🙊', message: l10n.library_export_empty);
      return;
    }

    final picked = await FilePicker.getDirectoryPath();
    if (picked == null || !mounted) return;
    if (!await _model.ensureStorageAccess()) {
      if (mounted) {
        showSnackBar(context,
            icon: '🔒', message: L10n.of(context).library_storage_permission_needed);
      }
      return;
    }
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(L10n.of(dialogContext).library_export_confirm_title),
        content: Text(L10n.of(dialogContext).library_export_confirm_body(_count)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(L10n.of(dialogContext).cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(L10n.of(dialogContext).library_storage_export),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    final result = await _model.exportTo(picked);
    if (!mounted) return;
    setState(() => _busy = false);

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
      showSnackBar(context, icon: '✅', message: l10n.library_export_done(result.copied, result.path!));
    }
  }

  Future<void> _toggleGallery(bool value) async {
    if (_busy || _loading) return;
    setState(() => _busy = true);
    final result = await _model.setGalleryVisible(value);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok) _galleryVisible = value;
    });

    final l10n = L10n.of(context);
    if (!result.ok) {
      showSnackBar(context, icon: '🙊', message: l10n.library_storage_permission_needed);
      return;
    }
    showSnackBar(
      context,
      icon: value ? '👀' : '🙈',
      message: value
          ? l10n.gallery_shown_count(result.affected)
          : l10n.gallery_hidden_count(result.affected),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.library_storage_manage, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(l10n.library_storage_manage_body, style: theme.textTheme.bodySmall),
            if (_count > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  l10n.library_stats(_count, formatBytes(_bytes)),
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
                ),
              ),
            const SizedBox(height: 12),
            if (_busy || _loading) const LinearProgressIndicator(),
            const SizedBox(height: 8),
            _StorageChoice(
              icon: Icons.shield_outlined,
              title: l10n.library_storage_hidden,
              body: l10n.library_storage_hidden_description,
              selected: _mode == LibraryStorageMode.hidden,
              onTap: _busy ? null : () => setState(() => _mode = LibraryStorageMode.hidden),
            ),
            if (_mode == LibraryStorageMode.hidden) ...[
              for (final volume in _volumes)
                ListTile(
                  contentPadding: const EdgeInsets.only(left: 44, right: 8),
                  leading: Icon(volume.isPrimary ? Icons.phone_android : Icons.sd_card_outlined),
                  title: Text(libraryVolumeLabel(l10n, volume)),
                  selected: volume == _selectedVolume,
                  trailing: Icon(volume == _selectedVolume
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked),
                  onTap: _busy ? null : () => setState(() => _selectedVolume = volume),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(44, 0, 8, 12),
                child: Text(
                  '${l10n.library_storage_hidden_note}\n${l10n.library_storage_android10_note}',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                ),
              ),
            ],
            const Divider(height: 1),
            _StorageChoice(
              icon: Icons.folder_outlined,
              title: l10n.library_storage_visible,
              body: l10n.library_storage_visible_description,
              selected: _mode == LibraryStorageMode.visible,
              onTap: _busy ? null : () => setState(() => _mode = LibraryStorageMode.visible),
            ),
            if (_mode == LibraryStorageMode.visible) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(44, 0, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _visibleParent == null
                            ? l10n.library_storage_no_folder
                            : p.join(_visibleParent!, libraryFolderName),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    TextButton(
                      onPressed: _busy ? null : _pickVisible,
                      child: Text(l10n.library_storage_pick_folder),
                    ),
                  ],
                ),
              ),
              if (!_model.isHidden)
                SwitchListTile(
                  contentPadding: const EdgeInsets.only(left: 44, right: 8),
                  value: _galleryVisible,
                  onChanged: _busy ? null : _toggleGallery,
                  secondary: Icon(_galleryVisible
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined),
                  title: Text(l10n.show_in_gallery),
                  subtitle: Text(l10n.library_storage_show_in_gallery_note),
                ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _busy || _loading ? null : _export,
                  icon: const Icon(Icons.ios_share),
                  label: Text(l10n.library_storage_export),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _canApply ? _apply : null,
                  child: _busy
                      ? const SizedBox(
                          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(l10n.library_storage_apply),
                ),
              ],
            ),
            if (!_model.isConfigured && _count == 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(l10n.library_storage_empty_note, style: theme.textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }
}

class _StorageChoice extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final bool selected;
  final VoidCallback? onTap;

  const _StorageChoice({
    required this.icon,
    required this.title,
    required this.body,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: selected ? theme.colorScheme.secondaryContainer.withValues(alpha: 0.35) : null,
      child: ListTile(
        onTap: onTap,
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(body),
        trailing: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked),
      ),
    );
  }
}
