import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:pref/pref.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/library/library_model.dart';
import 'package:quax/ui/errors.dart';

/// First-run wizard, Hentoid-style: the app is unusable until the storage
/// permission is granted and the hidden media library folder is picked. Only
/// then [onFinished] replaces the wizard with the home screen.
class OnboardingScreen extends StatefulWidget {
  final VoidCallback onFinished;

  const OnboardingScreen({super.key, required this.onFinished});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> with WidgetsBindingObserver {
  static const _storageChannel = MethodChannel('browser_resolver');
  static const _steps = 4;

  final PageController _controller = PageController();

  late final LibraryModel _library;
  bool _initialized = false;
  int _step = 0;
  bool _hasAccess = false;
  bool _configured = false;
  bool _visibleInGallery = false;
  bool _busy = false;

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
    _configured = _library.isConfigured;
    _visibleInGallery = _library.galleryVisible;
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
      final granted = await _storageChannel.invokeMethod<bool>('hasAllFilesAccess');
      if (mounted) setState(() => _hasAccess = granted == true);
    } on Exception {
      if (mounted) setState(() => _hasAccess = false);
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

  Future<void> _pickFolder() async {
    setState(() => _busy = true);
    final error = ValueNotifier<String?>(null);
    final ok = await _library.setupLibrary(error: error);
    if (!mounted) return;
    setState(() => _busy = false);

    if (ok) {
      setState(() {
        _configured = true;
        _visibleInGallery = _library.galleryVisible;
      });
      return;
    }

    if (error.value == 'storage_permission_needed') {
      await _refreshAccess();
      if (mounted) {
        showSnackBar(context, icon: '🔒', message: L10n.of(context).library_storage_permission_needed);
      }
      return;
    }

    if (error.value != null) {
      showSnackBar(context, icon: '🙊', message: error.value!);
    }
  }

  Future<void> _toggleGalleryVisible(bool value) async {
    final ok = await _library.setGalleryVisible(value);
    if (ok && mounted) {
      setState(() => _visibleInGallery = value);
    }
  }

  bool get _canAdvance => switch (_step) {
        0 => true,
        1 => _hasAccess,
        2 => _configured,
        _ => true,
      };

  void _next() => _controller.nextPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut);

  void _back() => _controller.previousPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut);

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
          TextButton(
            onPressed: _refreshAccess,
            child: Text(l10n.retry),
          ),
        ],
      ),
    );
  }

  Widget _buildFolderStep() {
    final l10n = L10n.of(context);

    return _StepView(
      icon: Icons.folder_outlined,
      title: l10n.library_setup_title,
      body: l10n.library_setup_description,
      extra: Column(
        children: [
          if (_busy)
            const CircularProgressIndicator()
          else if (_configured)
            Column(
              children: [
                Chip(
                  avatar: const Icon(Icons.check_circle_outline, size: 18),
                  label: Text(_library.libraryPath, overflow: TextOverflow.ellipsis),
                ),
                TextButton(
                  onPressed: _pickFolder,
                  child: Text(l10n.library_setup_pick),
                ),
              ],
            )
          else
            FilledButton.icon(
              onPressed: _hasAccess ? _pickFolder : _requestAccess,
              icon: const Icon(Icons.folder_open),
              label: Text(l10n.library_setup_pick),
            ),
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
        child: SwitchListTile(
          value: _visibleInGallery,
          onChanged: _configured ? _toggleGalleryVisible : null,
          secondary: Icon(_visibleInGallery ? Icons.visibility_outlined : Icons.visibility_off_outlined),
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
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Row(
        children: [
          if (_step > 0)
            TextButton(
              onPressed: _back,
              child: Text(l10n.back),
            ),
          const Spacer(),
          FilledButton(
            onPressed: _canAdvance ? (isLast ? widget.onFinished : _next) : null,
            child: Text(isLast ? l10n.setup_finish : l10n.next),
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

  const _StepView({required this.icon, required this.title, required this.body, this.extra});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: theme.colorScheme.primary),
          const SizedBox(height: 24),
          Text(title, style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Text(body, style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
          if (extra != null) ...[
            const SizedBox(height: 24),
            extra!,
          ],
        ],
      ),
    );
  }
}
