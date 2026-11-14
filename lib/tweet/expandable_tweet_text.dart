import 'package:material_ui/material_ui.dart';
import 'package:quax/generated/l10n.dart';

class ExpandableTweetText extends StatefulWidget {
  final List<InlineSpan> textSpans;
  final VoidCallback? onTap;
  final int? maxLines;

  const ExpandableTweetText({
    super.key,
    required this.textSpans,
    this.onTap,
    this.maxLines = 8,
  });

  @override
  ExpandableTweetTextState createState() => ExpandableTweetTextState();
}

class ExpandableTweetTextState extends State<ExpandableTweetText> {
  bool _isExpanded = false;

  // Answering "does this overflow?" with a throwaway TextPainter is the most
  // expensive part of building a card, and the feed rebuilds its tiles often
  // (freshness tags, consumers, scroll-driven rebuilds). The answer only
  // depends on the text, the width, the text scale and the direction, so it is
  // measured once and reused until one of those changes.
  double? _measuredAtWidth;
  double? _measuredScale;
  TextDirection? _measuredDirection;
  TextStyle? _measuredStyle;
  bool? _measuredTruncated;

  /// Test-only: the result of the last overflow measurement, or null when the
  /// text has not been measured yet.
  bool? get debugMeasuredTruncated => _measuredTruncated;

  bool _textIsTruncated(double width) {
    if (!mounted || widget.maxLines == null) return false;

    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    // The direction the text will actually be laid out in, not a hardcoded ltr:
    // measuring an Arabic or Hebrew tweet left-to-right gives the wrong line
    // count, so the "show more" button appears on text that is not truncated —
    // or, worse, is missing on text that is, leaving the reader with a silently
    // clipped post and no way to expand it. It also belongs in the memo key, or
    // switching between an LTR and an RTL tweet at the same width reuses the
    // LTR answer.
    final direction = Directionality.of(context);
    // Measure with the style the Text.rich below actually draws with: the
    // engine default has no letterSpacing/height, so a post that just fits on
    // line 8 in the measurement wraps to line 9 when drawn and loses its
    // "show more" button.
    final style = DefaultTextStyle.of(context).style;
    if (_measuredTruncated != null &&
        _measuredAtWidth == width &&
        _measuredScale == scale &&
        _measuredDirection == direction &&
        _measuredStyle == style) {
      return _measuredTruncated!;
    }

    final painter = TextPainter(
      text: TextSpan(style: style, children: widget.textSpans),
      textDirection: direction,
      textScaler: MediaQuery.textScalerOf(context),
    );

    painter.layout(maxWidth: width);
    final truncated = painter.computeLineMetrics().length > widget.maxLines!;
    painter.dispose();

    _measuredAtWidth = width;
    _measuredScale = scale;
    _measuredDirection = direction;
    _measuredStyle = style;
    _measuredTruncated = truncated;
    return truncated;
  }

  @override
  void didUpdateWidget(ExpandableTweetText oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (!identical(oldWidget.textSpans, widget.textSpans) || oldWidget.maxLines != widget.maxLines) {
      _measuredTruncated = null;
    }
  }

  /// Plain [Text] inside a [SelectionArea] instead of [SelectableText]: the
  /// latter is built on an EditableText, which is far heavier per card. The
  /// area keeps the text selectable, and the gesture detector keeps the
  /// tap-to-open behaviour SelectableText used to provide.
  Widget _buildText({int? maxLines}) {
    return SelectionArea(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Text.rich(TextSpan(children: widget.textSpans), maxLines: maxLines),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Measure against the width the text is actually laid out in: using
        // the raw screen width under-reported truncation (the card insets the
        // text), so long posts lost their "show more" button.
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final textIsTruncated = _textIsTruncated(width);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!_isExpanded && textIsTruncated)
              ShaderMask(
                shaderCallback: (bounds) {
                  return LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black,
                      Colors.black,
                      Colors.black,
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.6, 0.8, 1.0],
                  ).createShader(bounds);
                },
                blendMode: BlendMode.dstIn,
                child: _buildText(maxLines: widget.maxLines),
              )
            else
              _buildText(maxLines: _isExpanded || !textIsTruncated ? null : widget.maxLines),
            if (!_isExpanded && textIsTruncated)
              Align(
                alignment: Alignment.centerLeft,
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      _isExpanded = true;
                    });
                  },
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8, left: 2),
                    child: Text(
                      L10n.of(context).clickToShowMore,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
