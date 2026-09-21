import 'package:flutter/services.dart';
import 'package:flutter_triple/flutter_triple.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pref/pref.dart';
import 'package:provider/provider.dart';
import 'package:quax/constants.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/saved/folder_picker.dart';
import 'package:quax/saved/liked_tweet_model.dart';
import 'package:quax/saved/saved_tab_order.dart';
import 'package:quax/saved/saved_tweet_folder_model.dart';
import 'package:quax/saved/saved_tweet_model.dart';
import 'package:quax/saved/saved_tweet_tile.dart';
import 'package:quax/ui/errors.dart';

/// Posts saved on the device, with a folder filter strip above the list.
/// Shown as a tab of the Like screen; the strip layout (order and visibility)
/// is configured in [SavedFoldersScreen] behind the folder-manager button.
class SavedView extends StatefulWidget {
  const SavedView({super.key});

  @override
  State<SavedView> createState() => _SavedViewState();
}

class _SavedViewState extends State<SavedView> with AutomaticKeepAliveClientMixin<SavedView> {
  String _filter = savedTabAll;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    context.read<SavedTweetModel>().listSavedTweets();
    context.read<SavedTweetFolderModel>().listFolders();
    context.read<LikedTweetModel>().listLikedTweets();
  }

  Future<void> _refresh() async {
    // Silent reload: keeps the current list on screen while the RefreshIndicator
    // spinner runs, and swaps in the fresh data only once it is ready.
    if (_filter == savedTabFavorites) {
      await context.read<LikedTweetModel>().refreshLikedTweets();
    } else {
      await context.read<SavedTweetModel>().refreshSavedTweets();
    }
  }

  Future<void> _openFolderManager() async {
    await Navigator.pushNamed(context, routeSavedFolders);
    if (!mounted) {
      return;
    }

    await context.read<SavedTweetFolderModel>().listFolders();
    if (mounted) {
      setState(() {});
    }
  }

  String _emptyMessage(String filter) {
    return switch (filter) {
      savedTabAll => L10n.of(context).you_have_not_saved_any_tweets_yet,
      savedTabFavorites => L10n.of(context).no_liked_posts_yet,
      _ => L10n.of(context).library_is_empty,
    };
  }

  List<SavedTweet> _applyFilter(List<SavedTweet> tweets, String filter) {
    return switch (filter) {
      savedTabAll => tweets,
      savedTabUnfiled => tweets.where((e) => e.folderId == null).toList(),
      _ => tweets.where((e) => e.folderId == filter).toList(),
    };
  }

  bool _isTokenVisible(String token, BasePrefService prefs) {
    return switch (token) {
      savedTabAll => prefs.get<bool>(optionSavedShowAllTab) ?? true,
      savedTabUnfiled => prefs.get<bool>(optionSavedShowUnfiledTab) ?? true,
      savedTabFavorites => prefs.get<bool>(optionSavedShowFavoritesTab) ?? true,
      _ => true,
    };
  }

  String _tokenLabel(String token, List<SavedTweetFolder> folders) {
    return switch (token) {
      savedTabAll => L10n.of(context).all,
      savedTabUnfiled => L10n.of(context).unfiled,
      savedTabFavorites => L10n.of(context).favorites,
      _ => folders.firstWhere((f) => f.id == token).name,
    };
  }

  Widget _folderChip(String token, List<SavedTweetFolder> folders) {
    var isFolder = token != savedTabAll && token != savedTabUnfiled && token != savedTabFavorites;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: GestureDetector(
        onLongPress: isFolder ? () => _showFolderMenu(token, _tokenLabel(token, folders)) : null,
        child: Theme(
          data: Theme.of(context).copyWith(
            splashFactory: NoSplash.splashFactory,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
          ),
          child: ChoiceChip(
            label: Text(_tokenLabel(token, folders)),
            selected: _filter == token,
            showCheckmark: false,
            shape: const StadiumBorder(),
            side: BorderSide.none,
            onSelected: (_) => setState(() => _filter = token),
          ),
        ),
      ),
    );
  }

  Future<void> _showFolderMenu(String folderId, String label) async {
    var folderModel = context.read<SavedTweetFolderModel>();
    var matches = folderModel.state.where((f) => f.id == folderId);
    if (matches.isEmpty) {
      return;
    }
    var folder = matches.first;

    await HapticFeedback.lightImpact();
    if (!mounted) {
      return;
    }

    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              leading: const Icon(Icons.edit_outlined),
              title: Text(L10n.of(sheetContext).rename),
              onTap: () {
                Navigator.pop(sheetContext);
                showCreateFolderDialog(context, folderModel, existing: folder);
              },
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              leading: const Icon(Icons.delete_outline),
              title: Text(L10n.of(sheetContext).delete),
              onTap: () async {
                Navigator.pop(sheetContext);
                var deleted = await showDeleteFolderDialog(context, folderModel, folder);
                if (deleted && mounted && _filter == folderId) {
                  setState(() => _filter = savedTabAll);
                }
              },
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              leading: const Icon(Icons.folder_copy_outlined),
              title: Text(L10n.of(sheetContext).manage_folders),
              onTap: () async {
                Navigator.pop(sheetContext);
                await _openFolderManager();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFolderStrip(List<String> tokens, List<SavedTweetFolder> folders) {
    return SizedBox(
      height: 52,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(children: [for (var token in tokens) _folderChip(token, folders)]),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.folder_copy_outlined),
              tooltip: L10n.of(context).manage_folders,
              onPressed: _openFolderManager,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(String filter) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(child: Text(_emptyMessage(filter))),
        ),
      ),
    );
  }

  Widget _buildList({required int itemCount, required SavedTweetTile Function(int) tileAt}) {
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: 4),
      itemCount: itemCount,
      itemBuilder: (context, index) => tileAt(index),
    );
  }

  Widget _buildSavedBody(String filter) {
    var model = context.read<SavedTweetModel>();

    return ScopedBuilder<SavedTweetModel, List<SavedTweet>>.transition(
      store: model,
      onError: (_, e) => FullPageErrorWidget(
        error: e,
        stackTrace: null,
        prefix: L10n.current.unable_to_load_the_tweets,
        onRetry: () => model.listSavedTweets(),
      ),
      onLoading: (_) => const Center(child: CircularProgressIndicator()),
      onState: (_, data) {
        var filtered = _applyFilter(data, filter);

        return RefreshIndicator(
          onRefresh: _refresh,
          child: filtered.isEmpty
              ? _buildEmptyState(filter)
              : _buildList(
                  itemCount: filtered.length,
                  tileAt: (i) => SavedTweetTile(id: filtered[i].id, content: filtered[i].content)),
        );
      },
    );
  }

  Widget _buildFavoritesBody() {
    var model = context.read<LikedTweetModel>();

    return ScopedBuilder<LikedTweetModel, List<LikedTweet>>.transition(
      store: model,
      onError: (_, e) => FullPageErrorWidget(
        error: e,
        stackTrace: null,
        prefix: L10n.current.unable_to_load_the_tweets,
        onRetry: () => model.listLikedTweets(),
      ),
      onLoading: (_) => const Center(child: CircularProgressIndicator()),
      onState: (_, data) => RefreshIndicator(
        onRefresh: _refresh,
        child: data.isEmpty
            ? _buildEmptyState(savedTabFavorites)
            : _buildList(
                itemCount: data.length,
                tileAt: (i) => SavedTweetTile(id: data[i].id, content: data[i].content)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    var prefs = PrefService.of(context, listen: false);
    var folderModel = context.read<SavedTweetFolderModel>();

    return ScopedBuilder<SavedTweetFolderModel, List<SavedTweetFolder>>(
      store: folderModel,
      onState: (context, folders) {
        var tokens = orderedSavedTabs(folders, prefs.get(optionSavedTabOrder))
            .where((token) => _isTokenVisible(token, prefs))
            .toList();
        var filter = tokens.contains(_filter) ? _filter : savedTabAll;

        return Column(
          children: [
            _buildFolderStrip(tokens, folders),
            Expanded(
              child: filter == savedTabFavorites ? _buildFavoritesBody() : _buildSavedBody(filter),
            ),
          ],
        );
      },
    );
  }
}
