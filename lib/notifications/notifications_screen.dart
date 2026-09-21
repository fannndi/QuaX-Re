import 'package:flutter_triple/flutter_triple.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quax/client/client.dart';
import 'package:quax/constants.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/status.dart';
import 'package:quax/tweet/conversation.dart';
import 'package:quax/tweet/tweet_context_scope.dart';
import 'package:quax/ui/errors.dart';
import 'package:quax/user.dart';

/// Notifications timeline state: notification aggregates and embedded tweets
/// interleaved as X returns them, paged through the bottom cursor.
class NotifsModel extends Store<List<Object>> {
  String? _cursorBottom;
  bool _reachedEnd = false;
  bool _loadingMore = false;

  NotifsModel() : super([]);

  bool get reachedEnd => _reachedEnd;

  Future<void> loadInitial() async {
    _cursorBottom = null;
    _reachedEnd = false;
    await execute(() async {
      final page = await Twitter.getNotificationsTimeline();
      _cursorBottom = page.cursorBottom;
      _reachedEnd = page.cursorBottom == null;
      return <Object>[...page.entries];
    });
  }

  Future<void> loadMore() async {
    final cursor = _cursorBottom;
    if (_loadingMore || _reachedEnd || cursor == null) return;
    _loadingMore = true;

    try {
      final page = await Twitter.getNotificationsTimeline(cursor: cursor);
      _cursorBottom = page.cursorBottom;
      if (page.cursorBottom == null) _reachedEnd = true;
      update([...state, ...page.entries], force: true);
    } finally {
      _loadingMore = false;
    }
  }
}

/// The account's notifications, opened from the feed's app bar bell.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final NotifsModel _model = NotifsModel();

  @override
  void initState() {
    super.initState();
    _model.loadInitial();
  }

  @override
  void dispose() {
    _model.destroy();
    super.dispose();
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.metrics.pixels < notification.metrics.maxScrollExtent - 400) return false;
    _model.loadMore();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return TweetContextScope(
      child: Scaffold(
        appBar: AppBar(
          title: Text(L10n.of(context).notifications),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: L10n.of(context).refresh,
              onPressed: _model.loadInitial,
            ),
          ],
        ),
        body: ScopedBuilder<NotifsModel, List<Object>>.transition(
          store: _model,
          onError: (_, e) => ScaffoldErrorWidget(
            prefix: L10n.current.unable_to_load_the_tweets,
            error: e,
            stackTrace: null,
            onRetry: _model.loadInitial,
            retryText: L10n.current.retry,
          ),
          onLoading: (_) => const Center(child: CircularProgressIndicator()),
          onState: (_, items) => RefreshIndicator(
            onRefresh: _model.loadInitial,
            child: items.isEmpty
                ? ListView(children: [
                    Padding(
                      padding: const EdgeInsets.all(32),
                      child: Center(
                        child:
                            Text(L10n.of(context).no_notifications_yet, style: Theme.of(context).textTheme.bodyLarge),
                      ),
                    ),
                  ])
                : NotificationListener<ScrollNotification>(
                    onNotification: _onScroll,
                    child: ListView.builder(
                      itemCount: items.length + (_model.reachedEnd ? 0 : 1),
                      itemBuilder: (context, index) {
                        if (index >= items.length) {
                          return const Padding(
                            padding: EdgeInsets.all(16),
                            child: Center(child: CircularProgressIndicator()),
                          );
                        }
                        final item = items[index];
                        return item is NotificationEntry
                            ? _NotifTile(entry: item)
                            : TweetConversation(
                                id: (item as TweetChain).id,
                                tweets: item.tweets,
                                username: null,
                                isPinned: item.isPinned,
                              );
                      },
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _NotifTile extends StatelessWidget {
  final NotificationEntry entry;

  const _NotifTile({required this.entry});

  IconData get _icon {
    switch (entry.icon) {
      case 'heart_icon':
        return Icons.favorite;
      case 'retweet_icon':
      case 'repost_icon':
        return Icons.repeat;
      case 'reply_icon':
        return Icons.reply;
      case 'follow_icon':
        return Icons.person_add;
      case 'bell_icon':
        return Icons.notifications_active;
      default:
        return Icons.notifications;
    }
  }

  void _open(BuildContext context) {
    final url = entry.url;
    if (url == null) return;
    final match = RegExp(r'/status/(\d+)').firstMatch(url);
    if (match == null) return;
    Navigator.pushNamed(context, routeStatus,
        arguments: StatusScreenArguments(id: match.group(1)!, username: null));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return InkWell(
      onTap: () => _open(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (entry.senderAvatarUrl != null)
              UserAvatar(uri: entry.senderAvatarUrl, size: 36)
            else
              Icon(_icon, size: 24, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(_icon, size: 16, color: scheme.primary),
                      const SizedBox(width: 6),
                      if (entry.senderName != null)
                        Expanded(
                          child: Text(entry.senderName!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelLarge),
                        ),
                    ],
                  ),
                  if (entry.message != null) ...[
                    const SizedBox(height: 2),
                    Text(entry.message!, style: theme.textTheme.bodyMedium),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
