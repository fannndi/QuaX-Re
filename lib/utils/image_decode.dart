import 'package:material_ui/material_ui.dart';

/// Physical width to decode an image at when it is drawn [logicalWidth] points
/// wide on this screen. Decoding at the source resolution costs memory and
/// raster time the display cannot show, and the wasted decodes are paid while
/// the list is scrolling; [maxWidth] keeps high-DPI and tablet screens from
/// decoding more detail than they can use.
int decodeWidthFor(BuildContext context, double logicalWidth, {int maxWidth = 1440}) =>
    physicalDecodeWidth(logicalWidth, MediaQuery.devicePixelRatioOf(context), maxWidth: maxWidth);

/// Pure form of [decodeWidthFor], so rounding and clamping stay testable.
int physicalDecodeWidth(double logicalWidth, double devicePixelRatio, {int maxWidth = 1440}) {
  final physical = (logicalWidth * devicePixelRatio).round();
  return physical < 1 ? 1 : (physical > maxWidth ? maxWidth : physical);
}

/// How many decoded bitmaps the app is allowed to keep.
///
/// Flutter's default is 1000 entries / 100 MiB. A 1080-px-wide photo is about
/// 4.6 MB decoded, so twenty of them filled the whole budget — while the same
/// process also holds live video decoders (~35 MB each) and a library of
/// thumbnails. A 4 GB phone needs those pictures to leave room.
const int imageCacheMaxBytes = 48 * 1024 * 1024;
const int imageCacheMaxEntries = 500;

void applyImageCacheLimits(ImageCache cache) {
  cache.maximumSize = imageCacheMaxEntries;
  cache.maximumSizeBytes = imageCacheMaxBytes;
}
