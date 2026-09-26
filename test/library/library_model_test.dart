import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quax/library/library_model.dart';

/// The gallery's show/hide path is the feature's hot spot — it scans every
/// media file in the folder. These tests pin the value types the optimization
/// introduced: the streamed progress payload the switch paints, and the entry
/// shape that lets the grid filter and sort without re-folding names on every
/// keystroke.
void main() {
  group('GalleryProgress', () {
    test('Should read the payload the native pass sends', () {
      final progress = GalleryProgress.fromMap({'done': 40, 'total': 160, 'phase': 'scan'});

      expect(progress?.done, 40,
          reason: 'The switch shows how much of the pass is done, so the count has to survive the '
              'channel crossing');
      expect(progress?.total, 160,
          reason: 'Without the total there is no way to draw a determinate bar');
      expect(progress?.phase, 'scan',
          reason: 'The hide pass scans twice; the UI labels the second pass differently');
    });

    test('Should reject a payload without counts', () {
      expect(GalleryProgress.fromMap({'phase': 'scan'}), isNull,
          reason: 'A malformed event must not be painted as real progress, otherwise the bar '
              'jumps around on a provider that reports nothing useful');

      expect(GalleryProgress.fromMap('nonsense'), isNull,
          reason: 'Anything that is not the expected map is not progress');
    });

    test('Should fold the fraction into 0..1', () {
      const partial = GalleryProgress(done: 50, total: 200, phase: 'scan');
      expect(partial.fraction, 0.25,
          reason: 'LinearProgressIndicator needs a 0..1 value, so the model normalizes it');

      const empty = GalleryProgress(done: 0, total: 0, phase: 'scan');
      expect(empty.fraction, 0,
          reason: 'A pass that has not counted its files yet must not divide by zero');

      const overrun = GalleryProgress(done: 500, total: 400, phase: 'verify');
      expect(overrun.fraction, 1.0,
          reason: 'A provider reporting more callbacks than paths must not push the bar past full');
    });
  });

  group('LibraryEntry', () {
    test('Should fold the name once, for the search that reads it per keystroke', () {
      final entry = LibraryEntry(File(r'C:\lib\Handle-Clip.MP4'), true);

      expect(entry.name, 'Handle-Clip.MP4',
          reason: 'The tile shows the real file name, not the folded one');
      expect(entry.nameLower, 'handle-clip.mp4',
          reason: 'Search filters on the folded name; folding it at construction is what removed '
              'thousands of toLowerCase calls per keystroke');
    });

    test('Should rebuild from the primitives an isolate can send back', () {
      final entry = LibraryEntry.fromPrimitives('C:/lib/clip.mp4', true, 2048, 1700000000000);

      expect(entry.file.path, 'C:/lib/clip.mp4',
          reason: 'The grid opens files by path, so the path has to survive the isolate boundary');
      expect(entry.isVideo, isTrue,
          reason: 'Videos take the thumbnail route instead of decoding the frame inline');
      expect(entry.size, 2048,
          reason: 'The size sort compares this value, so it must not be dropped in transit');
      expect(entry.modified.millisecondsSinceEpoch, 1700000000000,
          reason: 'The default sort is by modification date, so the timestamp must survive too');
    });

    test('Should report size in megabytes', () {
      final entry = LibraryEntry.fromPrimitives('C:/lib/clip.mp4', true, 3145728, 0);

      expect(entry.sizeMb, 3.0,
          reason: 'The size column is shown in MB, so the conversion has to match the byte count');
    });

    test('Should keep an unreadable file listed with zero metadata', () {
      final entry = LibraryEntry.fromPrimitives('C:/lib/broken.mp4', false, 0, 0);

      expect(entry.size, 0,
          reason: 'A file that refused stat still belongs in the list; it just has no metadata');
      expect(entry.modified.millisecondsSinceEpoch, 0,
          reason: 'The epoch stands in for an unknown timestamp, sorting it last under newest-first');
    });
  });

  group('GalleryVisibilityResult', () {
    test('Should treat a queued request as not applied', () {
      expect(GalleryVisibilityResult.queued.ok, isFalse,
          reason: 'A pass folded into one already running must not be reported as applied, '
              'otherwise the switch keeps an optimistic flip the scan never performed');
    });

    test('Should carry the counts the UI reports back', () {
      const result = GalleryVisibilityResult(ok: true, affected: 12, remaining: 3);

      expect(result.affected, 12,
          reason: 'The snackbar tells the user how many files moved, so the count must be kept');
      expect(result.remaining, 3,
          reason: 'Leftover rows are what triggers the "may still appear" warning');
    });
  });
}
