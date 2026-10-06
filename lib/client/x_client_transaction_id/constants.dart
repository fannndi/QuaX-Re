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
final RegExp xWebEntryScriptRegex = RegExp(r'https://[\w.-]+/x-web/[\w./-]+\.js');

/// An asset chunk an x-web bundle imports, written relative to the importer.
final RegExp xWebChunkRegex = RegExp(r'''["'](\.?/?assets/[\w.-]+\.js)["']''');

/// The file holding the animation indices, under either build's name — the
/// legacy bundle called it `ondemand.s.<hash>a.js`, the x-web one
/// `sign.o-<hash>.js`. The `\b` before the name is what keeps a chunk called
/// `design.o-*.js` from passing as one.
final RegExp indicesFileRegex =
    RegExp(r'(?:\.{0,2}/)?[\w./-]*?\b(?:ondemand\.s|sign\.o)[\w.-]*\.js');
