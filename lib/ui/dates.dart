import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart';
import 'package:timeago/timeago.dart' as timeago;

final absoluteDateFormat = DateFormat.yMMMd('en').add_Hms();

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

  @override
  void initState() {
    super.initState();
    _useRelativeTimestamp = !widget.absoluteTimestamp;
  }

  @override
  void didUpdateWidget(Timestamp oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The setting is read once when a card mounts. Without this, turning
    // "absolute timestamp" on left every visible card on the old format until
    // it was recycled by scrolling.
    if (oldWidget.absoluteTimestamp != widget.absoluteTimestamp) {
      _useRelativeTimestamp = !widget.absoluteTimestamp;
    }
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
        : absoluteDateFormat.format(timestamp.toLocal());

    return GestureDetector(
      child: Text(formattedTime),
      onTap: () => setState(() => _useRelativeTimestamp = !_useRelativeTimestamp),
    );
  }
}
