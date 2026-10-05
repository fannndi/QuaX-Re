import 'package:material_ui/material_ui.dart';
import 'package:flutter_triple/flutter_triple.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/database/repository.dart';
import 'package:logging/logging.dart';

var defaultGroupIcon = '{"pack":"custom","key":"rss_feed"}';

class GroupsModel extends Store<List<SubscriptionGroup>> {
  static final log = Logger('GroupsModel');

  final Map<String, VoidCallback> _onGroupsReloaded = {};

  GroupsModel() : super([]);

  void addReloadListener(String key, VoidCallback callback) {
    _onGroupsReloaded[key] = callback;
  }

  void removeReloadListener(String key) {
    _onGroupsReloaded.remove(key);
  }

  Future reloadGroups() async {
    log.info('Listing subscriptions groups');

    await execute(() async {
      // Ordered by name only: nothing writes an ordering preference anymore, so
      // the old pref-driven column/direction would just be a constant.
      const orderByName = 'g.name COLLATE NOCASE ASC';

      const sql =
          "SELECT g.id, g.name, g.icon, g.color, g.created_at, COUNT(gm.profile_id) AS number_of_members FROM $tableSubscriptionGroup g LEFT JOIN $tableSubscriptionGroupMember gm ON gm.group_id = g.id WHERE g.id != '-1' GROUP BY g.id ORDER BY $orderByName";

      final rows = await Repository.read((db) => db.rawQuery(sql));
      return rows.map((e) => SubscriptionGroup.fromMap(e)).toList(growable: false);
    });
    for (final callback in _onGroupsReloaded.values) {
      callback();
    }
  }

  Future<List<String>> listGroupsForUser(String user) async {
    final rows = await Repository.read((db) => db.query(tableSubscriptionGroupMember,
        columns: ['group_id'], where: 'profile_id = ?', whereArgs: [user]));
    return rows.map((e) => e['group_id'] as String).toList(growable: false);
  }

  Future saveUserGroupMembership(String user, List<String> memberships) async {
    var database = await Repository.writable();

    var batch = database.batch();

    // First, clear all the memberships for the user
    batch.delete(tableSubscriptionGroupMember, where: 'profile_id = ?', whereArgs: [user]);

    // Then add all the new memberships
    for (var group in memberships) {
      batch.insert(tableSubscriptionGroupMember, {'group_id': group, 'profile_id': user});
    }

    await batch.commit();
    await reloadGroups();
  }
}
