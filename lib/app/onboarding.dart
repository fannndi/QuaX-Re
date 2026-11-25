import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:quax/app/design_tokens.dart';
import 'package:pref/pref.dart';
import 'package:quax/app/account_setup_step.dart';
import 'package:quax/client/account_vault.dart';
import 'package:quax/client/vault_paths.dart';
import 'package:quax/constants.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/library/library_model.dart';
import 'package:quax/library/library_storage_sheet.dart';
import 'package:quax/ui/errors.dart';
import 'package:quax/utils/storage_report.dart';

/// First-run wizard, Hentoid-style: the app is unusable until the storage
/// permission is granted and the hidden media library folder is picked. Only
/// then [onFinished] replaces the wizard with the home screen.
class OnboardingScreen extends StatefulWidget {
  final VoidCallback onFinished;

  const OnboardingScreen({super.key, required this.onFinished});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with WidgetsBindingObserver {
  static const _storageChannel = quaxMethodChannel;
  static const _steps = 5;

  final PageController _controller = PageController();

  late final LibraryModel _library;
  late final BasePrefService _prefs;
  List<LibraryVolume> _volumes = const [];
  LibraryVolume? _volume;
  bool _initialized = false;
  int _step = 0;
  bool _hasAccess = false;
  bool _configured = false;
  bool _visibleInGallery = false;
  bool _busy = false;
  List<ExistingLibrary> _existing = const [];
  bool _searchingExisting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;

    _library = LibraryModel(PrefService.of(context));
    _prefs = PrefService.of(context, listen: false);
    _configured = _library.isConfigured;
    _visibleInGallery = _library.galleryVisible;
    _loadVolumes();
    _refreshAccess();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from Android's all-files-access screen: refresh the status.
    if (state == AppLifecycleState.resumed) {
      _refreshAccess();
    }
  }

  Future<void> _refreshAccess() async {
    try {
      final granted = await _storageChannel.invokeMethod<bool>(
        'hasAllFilesAccess',
      );
      if (mounted) setState(() => _hasAccess = granted == true);
      // The first scan runs before the grant, when the card is unreadable.
      // Retry it as soon as Android says the app can see the folder.
      if (granted == true && mounted && _existing.isEmpty) {
        await _findExistingLibraries();
      }
    } on Exception {
      if (mounted) setState(() => _hasAccess = false);
    }
  }

  Future<void> _loadVolumes() async {
    try {
      final volumes = await _library.availableVolumes();
      if (!mounted) return;
      setState(() {
        _volumes = volumes;
        _volume = volumes.firstOrNull;
      });
    } on Exception {
      // The setup view offers a retry through the folder picker.
    }
    await _findExistingLibraries();
  }

  Future<void> _findExistingLibraries() async {
    if (_searchingExisting) return;
    _searchingExisting = true;
    final found = await _library.findExistingLibraries();
    if (!mounted) return;
    setState(() {
      _existing = found;
      _searchingExisting = false;
    });
  }

  Future<(bool, String?)> _withLibraryError(
    Future<bool> Function(ValueNotifier<String?>) setup,
  ) async {
    final error = ValueNotifier<String?>(null);
    try {
      final ok = await setup(error);
      return (ok, error.value);
    } finally {
      error.dispose();
    }
  }

  Future<void> _useExisting(ExistingLibrary candidate) async {
    setState(() => _busy = true);
    final (ok, errorMessage) = await _withLibraryError(
      (error) => _library.adoptExistingLibrary(candidate.path, error: error),
    );
    if (!mounted) return;
    setState(() => _busy = false);

    if (!ok) {
      if (errorMessage == 'storage_permission_needed') {
        await _refreshAccess();
        if (mounted) {
          showSnackBar(
            context,
            icon: '??',
            message: L10n.of(context).library_storage_permission_needed,
          );
        }
      } else {
        showSnackBar(
          context,
          icon: '??',
          message: L10n.of(context).library_existing_failed,
        );
      }
      return;
    }

    setState(() {
      _configured = true;
      _visibleInGallery = _library.galleryVisible;
      _existing = const [];
    });
    try {
      await ensureAccountFolder(vaultRootPathFor(_prefs));
    } catch (_) {
      // The account step still offers login and manual import when the
      // sibling folder cannot be created.
    }
  }

  Future<void> _requestAccess() async {
    try {
      await _storageChannel.invokeMethod('requestAllFilesAccess');
    } on Exception {
      // The system screen could not open; the Retry button covers it.
    }
    await _refreshAccess();
  }

  /// Fallback for ROMs that stop showing the permission dialog (MIUI does
  /// after two denials): the app details screen is the only way left.
  Future<void> _openSettings() async {
    try {
      await _storageChannel.invokeMethod('openAppSettings');
    } on Exception {
      // Nothing else the app can do; Retry stays as the fallback.
    }
  }

  Future<void> _pickFolder() async {
    setState(() => _busy = true);
    final (ok, errorMessage) = await _withLibraryError(
      (error) => _library.setupLibrary(error: error),
    );
    if (!mounted) return;
    setState(() => _busy = false);

    if (ok) {
      setState(() {
        _configured = true;
        _visibleInGallery = _library.galleryVisible;
      });
      try {
        await ensureAccountFolder(vaultRootPathFor(_prefs));
      } catch (_) {
        // The account step still offers login and manual import when the
        // sibling folder cannot be created.
      }
      await _offerImportOfOldFolder(p.dirname(_library.libraryPath));
      return;
    }

    if (errorMessage == 'storage_permission_needed') {
      await _refreshAccess();
      if (mounted) {
        showSnackBar(
          context,
          icon: '🔒',
          message: L10n.of(context).library_storage_permission_needed,
        );
      }
      return;
    }

    if (errorMessage != null) {
      showSnackBar(context, icon: '🙊', message: errorMessage);
    }
  }

  /// Old downloads often sit in the folder the user just picked (the days when
  /// the library did not exist): offer to move them in, Hentoid-style.
  Future<void> _offerImportOfOldFolder(String sourcePath) async {
    final count = await _library.countImportableIn(sourcePath);
    if (count == 0 || !mounted) return;

    final import = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(L10n.of(dialogContext).library_setup_title),
        content: Text(L10n.of(dialogContext).library_import_question),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(L10n.of(dialogContext).cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(L10n.of(dialogContext).library_import_existing),
          ),
        ],
      ),
    );

    if (import != true || !mounted) return;
    setState(() => _busy = true);
    await _library.importFromDirectory(sourcePath);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _toggleGalleryVisible(bool value) async {
    final ok = await _library.setGalleryVisible(value);
    if (ok && mounted) {
      setState(() => _visibleInGallery = value);
    }
  }

  bool get _canAdvance => switch (_step) {
    0 => true,
    // Hidden storage needs no permission, so this step must not block the
    // wizard: the visible-folder button asks for the grant when picked.
    1 => true,
    2 => _configured,
    _ => true,
  };

  void _next() => _controller.nextPage(
    duration: const Duration(milliseconds: 250),
    curve: Curves.easeOut,
  );

  void _back() => _controller.previousPage(
    duration: const Duration(milliseconds: 250),
    curve: Curves.easeOut,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _controller,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (index) => setState(() => _step = index),
                children: [
                  _StepView(
                    icon: Icons.video_library_outlined,
                    title: l10n.setup_welcome_title,
                    body: l10n.setup_welcome_body,
                  ),
                  _buildPermissionStep(),
                  _buildFolderStep(),
                  _StepView(
                    icon: Icons.people_outline,
                    title: l10n.setup_accounts_title,
                    body: l10n.setup_accounts_body,
                    extra: AccountSetupStep(
                      vaultRoot: vaultRootPathFor(_prefs),
                    ),
                  ),
                  _buildDoneStep(context),
                ],
              ),
            ),
            _buildProgress(),
            _buildFooter(context),
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionStep() {
    final l10n = L10n.of(context);

    return _StepView(
      icon: _hasAccess ? Icons.lock_open_outlined : Icons.lock_outline,
      title: l10n.setup_permission_title,
      body: l10n.setup_permission_body,
      extra: Column(
        children: [
          if (_hasAccess)
            Chip(
              avatar: const Icon(Icons.check_circle_outline, size: 18),
              label: Text(l10n.setup_permission_granted),
            )
          else
            FilledButton.icon(
              onPressed: _requestAccess,
              icon: const Icon(Icons.folder_special_outlined),
              label: Text(l10n.setup_permission_grant),
            ),
          const SizedBox(height: 8),
          TextButton(onPressed: _refreshAccess, child: Text(l10n.retry)),
          if (!_hasAccess)
            TextButton(
              onPressed: _openSettings,
              child: Text(l10n.setup_permission_open_settings),
            ),
        ],
      ),
    );
  }

  Future<void> _setupHidden() async {
    final volume = _volume;
    if (volume == null) return;

    setState(() => _busy = true);
    final (ok, errorMessage) = await _withLibraryError(
      (error) => _library.setupHiddenLibrary(volume, error: error),
    );
    if (!mounted) return;
    setState(() => _busy = false);

    if (ok) {
      setState(() {
        _configured = true;
        _visibleInGallery = false;
      });
      try {
        await ensureAccountFolder(vaultRootPathFor(_prefs));
      } catch (_) {
        // The account step still offers login and manual import when the
        // backup folder cannot be created.
      }
      return;
    }

    if (errorMessage == 'storage_permission_needed') {
      await _refreshAccess();
      if (mounted) {
        showSnackBar(
          context,
          icon: '🔒',
          message: L10n.of(context).library_storage_permission_needed,
        );
      }
      return;
    }
    if (errorMessage != null && mounted) {
      showSnackBar(context, icon: '🙊', message: errorMessage);
    }
  }

  Future<void> _manageStorage() async {
    final changed = await showLibraryStorageSheet(context, _prefs);
    if (!mounted) return;
    setState(() {
      _configured = _library.isConfigured;
      _visibleInGallery = _library.galleryVisible;
    });
    if (changed == true) await _loadVolumes();
  }

  Widget _buildExistingLibraries(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.folder_special_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.library_existing_found,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(l10n.library_existing_keep, style: theme.textTheme.bodySmall),
            for (final candidate in _existing) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  candidate.isHidden
                      ? Icons.shield_outlined
                      : Icons.folder_outlined,
                ),
                title: Text(
                  l10n.library_stats(
                    candidate.mediaCount,
                    formatBytes(candidate.bytes),
                  ),
                ),
                subtitle: Text(
                  candidate.path,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: _busy ? null : () => _useExisting(candidate),
                trailing: const Icon(Icons.chevron_right),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _busy ? null : () => _useExisting(candidate),
                  icon: const Icon(Icons.folder_open),
                  label: Text(l10n.library_existing_use),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFolderStep() {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);

    return _StepView(
      icon: Icons.video_library_outlined,
      title: l10n.library_setup_title,
      body: l10n.library_setup_description,
      extra: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_existing.isNotEmpty) _buildExistingLibraries(context),
          if (_searchingExisting)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: LinearProgressIndicator(),
            ),
          if (_configured)
            Card(
              child: ListTile(
                leading: Icon(
                  _library.isHidden
                      ? Icons.shield_outlined
                      : Icons.folder_outlined,
                ),
                title: Text(
                  _library.isHidden
                      ? l10n.library_storage_hidden
                      : l10n.library_storage_visible,
                ),
                subtitle: Text(
                  _library.libraryPath,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: TextButton(
                  onPressed: _busy ? null : _manageStorage,
                  child: Text(l10n.library_storage_change),
                ),
              ),
            )
          else ...[
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
                      Text(
                        l10n.library_storage_unavailable_body,
                        style: TextStyle(color: theme.colorScheme.error),
                      )
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final volume in _volumes)
                            ChoiceChip(
                              avatar: Icon(
                                volume.isPrimary
                                    ? Icons.phone_android
                                    : Icons.sd_card_outlined,
                              ),
                              label: Text(libraryVolumeLabel(l10n, volume)),
                              selected: _volume == volume,
                              onSelected: _busy
                                  ? null
                                  : (_) => setState(() => _volume = volume),
                            ),
                        ],
                      ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _busy || _volume == null ? null : _setupHidden,
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
                      onPressed: _busy
                          ? null
                          : (_hasAccess ? _pickFolder : _requestAccess),
                      icon: const Icon(Icons.folder_open),
                      label: Text(l10n.library_setup_pick),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDoneStep(BuildContext context) {
    final l10n = L10n.of(context);

    return _StepView(
      icon: Icons.check_circle_outline,
      title: l10n.setup_done_title,
      body: l10n.setup_done_body,
      extra: Card(
        margin: const EdgeInsets.symmetric(horizontal: 24),
        child: _library.isHidden
            ? ListTile(
                leading: const Icon(Icons.shield_outlined),
                title: Text(l10n.library_storage_hidden),
                subtitle: Text(l10n.library_hidden_status),
              )
            : SwitchListTile(
                value: _visibleInGallery,
                onChanged: _configured ? _toggleGalleryVisible : null,
                secondary: Icon(
                  _visibleInGallery
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                title: Text(l10n.show_in_gallery),
              ),
      ),
    );
  }

  Widget _buildProgress() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < _steps; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: _step == i ? 20 : 8,
              height: 8,
              decoration: BoxDecoration(
                color: _step == i
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    final l10n = L10n.of(context);
    final isLast = _step == _steps - 1;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.sm,
        AppSpace.lg,
        AppSpace.lg,
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _step > 0 ? _back : null,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, AppSize.buttonLarge),
              ),
              child: Text(l10n.back),
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: FilledButton(
              onPressed: _canAdvance
                  ? (isLast ? widget.onFinished : _next)
                  : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, AppSize.buttonLarge),
              ),
              child: Text(isLast ? l10n.setup_finish : l10n.next),
            ),
          ),
        ],
      ),
    );
  }
}

class _StepView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final Widget? extra;

  const _StepView({
    required this.icon,
    required this.title,
    required this.body,
    this.extra,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpace.xl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 56, color: theme.colorScheme.primary),
          const SizedBox(height: AppSpace.lg),
          Text(
            title,
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpace.md),
          Text(
            body,
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          if (extra != null) ...[const SizedBox(height: AppSpace.xl), extra!],
        ],
      ),
    );
  }
}
