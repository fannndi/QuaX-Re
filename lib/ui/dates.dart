import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart';
import 'package:timeago/timeago.dart' as timeago;

final absoluteDateFormat = DateFormat.yMMMd('en').add_Hms();
final absoluteDateFormat12h = DateFormat.yMMMd('en').add_jms();

String createRelativeDate(DateTime dateTime) {
  return timeago.format(dateTime, locale: 'en');
}

class Timestamp extends StatefulWidget {
  final DateTime? timestamp;
  final bool absoluteTimestamp;

  const Timestamp({super.key, required this.timestamp, this.absoluteTimestamp = false});

  @override
  State<Timestamp> createState() => _TimestampState();
}

class _TimestampState extends State<Timestamp> {
  // Seeded in initState, not in createState(): the latter is handed a State
  // that does not exist yet, and the field is flipped by the tap below.
  late bool _useRelativeTimestamp;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _useRelativeTimestamp = !widget.absoluteTimestamp;
    _startTicker();
  }

  /// A relative label is computed in build(), so a stationary card kept saying
  /// "now" until something else rebuilt it. One tick a minute is enough for
  /// timeago's minute/hour/day buckets.
  void _startTicker() {
    _ticker?.cancel();
    _ticker = _useRelativeTimestamp
        ? Timer.periodic(const Duration(minutes: 1), (_) {
            if (mounted) setState(() {});
          })
        : null;
  }

  @override
  void didUpdateWidget(Timestamp oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The setting is read once when a card mounts. Without this, turning
    // "absolute timestamp" on left every visible card on the old format until
    // it was recycled by scrolling.
    if (oldWidget.absoluteTimestamp != widget.absoluteTimestamp) {
      _useRelativeTimestamp = !widget.absoluteTimestamp;
      _startTicker();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final timestamp = widget.timestamp;
    if (timestamp == null) {
      return Container();
    }

    // Computed in build so a parent rebuild (the settings screen) reflects the
    // current preference immediately.
    final formattedTime = _useRelativeTimestamp
        ? createRelativeDate(timestamp)
        : (MediaQuery.alwaysUse24HourFormatOf(context) ? absoluteDateFormat : absoluteDateFormat12h)
            .format(timestamp.toLocal());

    return GestureDetector(
      child: Text(formattedTime),
      onTap: () => setState(() {
        _useRelativeTimestamp = !_useRelativeTimestamp;
        _startTicker();
      }),
    );
  }
}
