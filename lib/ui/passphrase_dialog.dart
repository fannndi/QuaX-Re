import 'package:material_ui/material_ui.dart';
import 'package:quax/generated/l10n.dart';

/// Asks for the vault passphrase. [confirm] adds a second field for a new
/// passphrase and checks the minimum length and the match before returning it.
Future<String?> showVaultPassphraseDialog(
  BuildContext context, {
  required bool confirm,
  String? title,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PassphraseDialog(confirm: confirm, title: title),
  );
}

class _PassphraseDialog extends StatefulWidget {
  final bool confirm;
  final String? title;

  const _PassphraseDialog({required this.confirm, this.title});

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _first = TextEditingController();
  final _second = TextEditingController();
  bool _show = false;
  String? _error;

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  void _submit() {
    final l10n = L10n.of(context);
    final first = _first.text.trim();
    if (first.length < 8) {
      setState(() => _error = l10n.account_backup_passphrase_hint);
      return;
    }
    if (widget.confirm && first != _second.text.trim()) {
      setState(() => _error = l10n.account_backup_passphrase_mismatch);
      return;
    }
    Navigator.pop(context, first);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return AlertDialog(
      title: Text(widget.title ?? l10n.account_backup),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _first,
              autofocus: true,
              obscureText: !_show,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: widget.confirm ? TextInputAction.next : TextInputAction.done,
              onSubmitted: widget.confirm ? null : (_) => _submit(),
              decoration: InputDecoration(
                labelText: l10n.account_backup_passphrase,
                suffixIcon: IconButton(
                  tooltip: _show ? l10n.account_backup_hide : l10n.account_backup_show,
                  icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                  onPressed: () => setState(() => _show = !_show),
                ),
              ),
            ),
            if (widget.confirm) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _second,
                obscureText: !_show,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(labelText: l10n.account_backup_passphrase_confirm),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ] else if (widget.confirm) ...[
              const SizedBox(height: 12),
              Text(l10n.account_backup_passphrase_hint,
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(l10n.ok),
        ),
      ],
    );
  }
}
