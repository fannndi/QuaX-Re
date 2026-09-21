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
