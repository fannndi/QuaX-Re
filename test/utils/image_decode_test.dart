import 'package:flutter_test/flutter_test.dart';
import 'package:quax/utils/image_decode.dart';

void main() {
  group('physicalDecodeWidth()', () {
    test('Should multiply the logical width by the device pixel ratio', () {
      expect(physicalDecodeWidth(360, 2.75), 990,
          reason: 'A 360pt-wide box on a 2.75x screen shows 990 physical pixels, so decoding less '
              'than that would be visibly soft and decoding more wastes memory');
    });

    test('Should round to the nearest pixel', () {
      expect(physicalDecodeWidth(360.2, 2.75), 991,
          reason: 'Fractional layouts are common; the decoded width has to be a whole number');
    });

    test('Should cap at maxWidth', () {
      expect(physicalDecodeWidth(1080, 3.0, maxWidth: 1440), 1440,
          reason: 'A 3x 1080pt tablet would ask for 3240px; capping keeps one photo from eating '
              'tens of megabytes of the image cache');
    });

    test('Should never ask for zero pixels', () {
      expect(physicalDecodeWidth(0, 2.75), 1,
          reason: 'A collapsed box still renders a one-pixel decode; passing 0 to cacheWidth trips '
              'the ResizeImage assertion');
    });
  });
}
