import 'dart:ui';

import 'package:flutter_triple/flutter_triple.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/database/repository.dart';
import 'package:quax/group/group_model.dart';
import 'package:quax/subscriptions/followed_users_index.dart';
import 'package:quax/utils/iterables.dart';
import 'package:logging/logging.dart';

class SubscriptionsModel extends Store<List<Subscription>> {
  static final log = Logger('SubscriptionsModel');

  final GroupsModel groupModel;
  final Map<String, VoidCallback> _onSubscriptionsReloaded = {};

  SubscriptionsModel(this.groupModel) : super([]);

  void addReloadListener(String key, VoidCallback callback) {
    _onSubscriptionsReloaded[key] = callback;
  }

  void removeReloadListener(String key) {
    _onSubscriptionsReloaded.remove(key);
  }

  Future<void> reloadSubscriptions() async {
    log.info('Listing subscriptions');

    await execute(() async {
      final users = (await Repository.read((db) => db.query(tableSubscription)))
          .map((e) => UserSubscription.fromMap(e))
          .toList();

      final searches = (await Repository.read((db) => db.query(tableSearchSubscription)))
          .map((e) => SearchSubscription.fromMap(e))
          .toList();

      // Ordered by name only: nothing writes an ordering preference anymore, so
      // the old pref-driven column, direction and custom-order branch would
      // just be constants.
      return [...users, ...searches].sorted((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())).toList();
    });
    for(final callback in _onSubscriptionsReloaded.values) {
      callback();
    }

    // The tweet headers label posts from followed accounts; search "subscriptions"
    // are query strings, not people, so they stay out of the index.
    FollowedUsersIndex().replaceAll(state.whereType<UserSubscription>().map((s) => s.id));
  }

  Future<void> _toggleSearchSubscribe(SearchSubscription user, bool currentlyFollowed) async {
    var database = await Repository.writable();

    await execute(() async {
      if (currentlyFollowed) {
        await database.delete(tableSearchSubscription, where: 'id = ?', whereArgs: [user.id]);
        await database.delete(tableSearchSubscriptionGroupMember, where: 'search_id = ?', whereArgs: [user.id]);

        state.removeWhere((e) => e.id == user.id);
      } else {
        await database.insert(tableSearchSubscription, {
          'id': user.id,
        });
      }

      // TODO: This is hardcore, but we need to resort the list and this is the easiest way
      await reloadSubscriptions();

      return state;
    });
  }

  Future<void> _toggleUserSubscribe(UserSubscription user, bool currentlyFollowed) async {
    var database = await Repository.writable();

    await execute(() async {
      if (currentlyFollowed) {
        await database.delete(tableSubscription, where: 'id = ?', whereArgs: [user.id]);
        await database.delete(tableSubscriptionGroupMember, where: 'profile_id = ?', whereArgs: [user.id]);

        state.removeWhere((e) => e.id == user.id);
      } else {
        await database.insert(tableSubscription, {
          'id': user.id,
          'screen_name': user.screenName,
          'name': user.name,
          'profile_image_url_https': user.profileImageUrlHttps,
          'verified': user.verified ? 1 : 0
        });
      }

      // TODO: This is hardcore, but we need to resort the list and this is the easiest way
      await reloadSubscriptions();

      return state;
    });

    await groupModel.reloadGroups();
  }

  Future<void> toggleSubscribe(Subscription user, bool currentlyFollowed) async {
    if (user is UserSubscription) {
      await _toggleUserSubscribe(user, currentlyFollowed);
    } else if (user is SearchSubscription) {
      await _toggleSearchSubscribe(user, currentlyFollowed);
    }

    await groupModel.reloadGroups();
  }

  Future<void> toggleInFeed(Subscription user, bool wasInFeed) async {
    var database = await Repository.writable();
    await execute(() async {
      await database.update(tableSubscription, {
        'in_Feed': wasInFeed ? 0 : 1
      }, where: 'id = ?', whereArgs: [user.id]);

      await reloadSubscriptions();

      return state;
    });
  }
}
