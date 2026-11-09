import 'package:path/path.dart' as p;
import 'package:pref/pref.dart';
import 'package:quax/constants.dart';

/// The shared-storage folder that holds `QuaXAccount`.
///
/// Before hidden storage existed the vault was a sibling of `QuaXLibrary`, so
/// the library parent was the answer. A hidden library now lives under
/// `Android/data`, which the system deletes on uninstall; keeping the vault
/// there would defeat its purpose. The explicit preference wins, and the old
/// derivation stays as a fallback for an install whose migration has not run
/// yet.
String vaultRootPathFor(BasePrefService prefs) {
  final explicit = prefs.get<String>(optionVaultRoot);
  if (explicit != null && explicit.isNotEmpty) return explicit;

  final library = prefs.get<String>(optionLibraryPath) ?? '';
  if (library.isEmpty) return '';
  final parent = p.dirname(library);
  return parent == '.' ? '' : parent;
}
