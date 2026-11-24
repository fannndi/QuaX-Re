const int additionalRandomNumber = 3;
const String defaultKeyword = 'obfiowerehiring';

const String onDemandFileUrlTemplate =
    'https://abs.twimg.com/responsive-web/client-web/ondemand.s.{filename}a.js';

final RegExp indicesRegex = RegExp(
  r'(\(\w{1}\[(\d{1,2})\],\s*16\))+',
  multiLine: true,
);

final RegExp onDemandFileRegex = RegExp(
  r''',(\d+):["']ondemand\.s["']''',
  multiLine: true,
);

/// The x-web build's entry bundle: the only script the page links directly.
final RegExp xWebEntryScriptRegex = RegExp(
  r'https://[\w.-]+/x-web/[\w./-]+\.js',
);

/// A precise static ES module import: either `from "path"` or a side-effect
/// `import "path"`. Dynamic `import(path)` expressions are intentionally excluded.
final RegExp staticImportRegex = RegExp(
  r'''\b(?:from|import)\s*(["'`])([\w./-]+\.js)\1''',
  multiLine: true,
);

/// A lazy module whose default export is invoked:
/// `import(path).then(module => module.default())`.
final RegExp defaultImportRegex = RegExp(
  r'''\bimport\s*\(\s*(["'`])([\w./-]+\.js)\1\s*\)\s*\.then\s*\(\s*\(?(\w+)\)?\s*=>\s*\3\.default\s*\(\s*\)''',
  multiLine: true,
);

const int maxStaticImportDepth = 2;
const int maxImportedAssets = 32;

/// The file holding the animation indices, under either build's name — the
/// legacy bundle called it `ondemand.s.<hash>a.js`, the x-web one
/// `sign.o-<hash>.js`. The `\b` before the name is what keeps a chunk called
/// `design.o-*.js` from passing as one.
final RegExp indicesFileRegex = RegExp(
  r'(?:\.{0,2}/)?[\w./-]*?\b(?:ondemand\.s|sign\.o)[\w.-]*\.js',
);
