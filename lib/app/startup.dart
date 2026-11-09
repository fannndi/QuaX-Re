import 'package:path/path.dart' as p;
import 'package:pref/pref.dart';
import 'package:quax/constants.dart';
import 'package:quax/library/library_model.dart';

Future<void> migrateLibraryStoragePrefs(BasePrefService prefs) async {
  final library = prefs.get<String>(optionLibraryPath) ?? '';
  if (library.isEmpty) return;

  final mode = prefs.get<String>(optionLibraryStorageMode) ?? '';
  final hidden = library.contains('${p.separator}Android${p.separator}data${p.separator}');
  if (mode.isEmpty) {
    await prefs.set(
      optionLibraryStorageMode,
      hidden ? libraryStorageHidden : libraryStorageVisible,
    );
  }

  // Before hidden storage existed the vault was a sibling of QuaXLibrary. Pin
  // that folder now, so moving the media into Android/data later cannot take
  // the encrypted backups with it. A library already inside Android/data has
  // its backups on the volume root instead: that tree is erased on uninstall.
  final vaultRoot = prefs.get<String>(optionVaultRoot) ?? '';
  if (vaultRoot.isEmpty) {
    final parent = hidden ? LibraryVolume(p.dirname(library)).vaultRoot : p.dirname(library);
    if (parent.isNotEmpty && parent != '.') {
      await prefs.set(optionVaultRoot, parent);
    }
  }
}

// One-time split of the former single "media size" pref into separate image and
// video quality settings, plus a data-saver toggle for its old "disabled" value.
Future<void> migrateMediaQualityPrefs(BasePrefService prefs) async {
  if (prefs.get<bool>(optionMediaQualitySplitMigrated) ?? false) {
    return;
  }

  final previous = prefs.get<String>(optionImageQuality);
  final disabled = previous == 'disabled';
  // The old "disabled" value carried no real quality, so fall back to Maximum.
  final quality = disabled ? 'large' : (previous ?? 'medium');

  await prefs.set(optionMediaDisableAutoload, disabled);
  await prefs.set(optionImageQuality, quality);
  await prefs.set(optionMediaVideoQuality, quality);
  await prefs.set(optionMediaQualitySplitMigrated, true);
}

