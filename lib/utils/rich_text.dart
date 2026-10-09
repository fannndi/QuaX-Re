import 'package:dart_twitter_api/twitter_api.dart';
import 'package:html_unescape/html_unescape.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import 'package:quax/constants.dart';
import 'package:quax/profile/profile.dart';
import 'package:quax/search/search.dart';
import 'package:quax/utils/urls.dart';
import 'package:quax/utils/iterables.dart';
import 'package:quax/utils/_entities.dart';

/// Compiled once: [_parseMentionsAndHashtags] runs per rendered post, and
/// [_convertRunesToText] per entity inside it — building these each time is
/// regex compilation and allocation for text that has not changed.
final _mentionOrHashtag = RegExp(r'(#|(?<=\W|^)@)\w+');
final _htmlUnescape = HtmlUnescape();

// RichText (not sure if it has an official name) is the way urls, mentions, hashtags... are integrated on
// twitter content (tweets and descriptions).
// It uses Entities (objects with fields such as display_url, url (t.co) and indices)

class RichTextPart {
  final InlineSpan? entity;
  String? plainText;

  RichTextPart(this.entity, this.plainText);

  @override
  String toString() {
    return plainText ?? '';
  }
}

List<InlineSpan> displayRichText(List<RichTextPart> richText) {
  return richText.map((e) {
    if (e.plainText != null) {
      return TextSpan(text: e.plainText);
    } else {
      return e.entity!;
    }
  }).toList();
}

// Generate all the tweet entities (mentions, hashtags, etc.) from the tweet text
List<RichTextPart> buildRichText(BuildContext context, String rawText, Object? rawEntities) {
  Runes runes = Runes(rawText);
  Iterable<int> runesAsIterable = runes.getRange(0, runes.length);

  List<Entity> entities = [];
  if (rawEntities != null) {
    entities = _parseEntities(context, rawEntities);
  }
  List<RichTextPart> richTextParts = [];

  int index = 0;
  for (var part in entities) {
    int start = part.getEntityStart();
    int end = part.getEntityEnd();

    // Add any text between the last entity's end and the start of this one
    var textPart = _convertRunesToText(runesAsIterable, index, start);
    _handleTextParts(context, textPart, richTextParts);

    // Then add the actual entity
    richTextParts.add(RichTextPart(part.getContent(), null));

    // Then set our index in the tweet text as the end of our entity
    index = end;
  }
  // And end by adding any text between the last entity and the end of the text
  var textPart = _convertRunesToText(runesAsIterable, index);
  _handleTextParts(context, textPart, richTextParts);

  return richTextParts;
}

// In descriptions, the hashtags and mentions are not seen as entities, so we parse them manually
void _handleTextParts(BuildContext context, String? text, List<RichTextPart> richTextParts) {
  if (text == null) return;
  List parsedText = _parseMentionsAndHashtags(context, text);
  for (var t in parsedText) {
    if (t is String) {
      richTextParts.add(RichTextPart(null, t));
    }
    if (t is InlineSpan) {
      richTextParts.add(RichTextPart(t, null));
    }
  }
}

List _parseMentionsAndHashtags(BuildContext context, String content) {
  List contentWidgets = [];

  // Split the string by any mentions or hashtags, and turn those into links
  content.splitMapJoin(_mentionOrHashtag, onMatch: (match) {
    var full = match.group(0);
    var type = match.group(1);
    if (type == null || full == null) {
      return '';
    }

    var onTap = () async {};
    if (type == '#') {
      onTap = () async {
        Navigator.pushNamed(context, routeSearch,
            arguments:
                SearchArguments(1, focusInputOnOpen: false, query: full));
      };
    }
    if (type == '@') {
      onTap = () async {
        Navigator.pushNamed(context, routeProfile,
            arguments:
                ProfileScreenArguments.fromScreenName(full.substring(1), null));
      };
    }
    contentWidgets.add(TextSpan(
        text: full,
        style: TextStyle(color: Theme.of(context).colorScheme.secondary),
        recognizer: TapGestureRecognizer()..onTap = onTap));
    return type;
  }, onNonMatch: (text) {
    contentWidgets.add(text);
    return text;
  });

  return contentWidgets;
}

String? _convertRunesToText(Iterable<int> runes, int start, [int? end]) {
  // One allocation instead of a String per code unit joined at the end.
  final string = String.fromCharCodes(runes.getRange(start, end));
  if (string.isEmpty) {
    return null;
  }
  return _htmlUnescape.convert(string);
}

List<Entity> _parseEntities(BuildContext context, dynamic newEntities) {
  List<Entity> entities = [];
  if (newEntities == null) return entities;

  if (newEntities is Map<String, dynamic>){
    // try using newEntities as a raw json object
    newEntities = Entities.fromJson(newEntities);
  }

  if (newEntities is! Entities && newEntities is! UserEntityUrl){
      return entities;
  }

  // in tweets all entities types can be present (Entities object)
  // but in profile description there can be only urls (UserEntityUrl object)
  if (newEntities is Entities) {
    for (Media media in newEntities.media ?? []) {
      entities.add(MediaEntity(media));
    }

    for (Hashtag hashtag in newEntities.hashtags ?? []) {
      entities.add(HashtagEntity(
          hashtag,
          () => Navigator.pushNamed(context, routeSearch,
              arguments: SearchArguments(1,
                  focusInputOnOpen: false, query: '#${hashtag.text}'))));
    }

    for (UserMention mention in newEntities.userMentions ?? []) {
      entities.add(UserMentionEntity(
          mention,
          () => Navigator.pushNamed(context, routeProfile,
              arguments:
                  ProfileScreenArguments(mention.idStr, mention.screenName, null))));
    }
  }

  for (Url url in newEntities.urls ?? []) {
    entities.add(UrlEntity(url, () async {
      String? uri = url.expandedUrl;
      if (uri == null ||
          (uri.length > 33 &&
              uri.substring(0, 33) == 'https://twitter.com/i/web/status/') ||
          (uri.length > 27 &&
              uri.substring(0, 27) == 'https://x.com/i/web/status/')) {
        return;
      }
      await openUri(context, uri);
    }));
  }

  entities.sort((a, b) => a.getEntityStart().compareTo(b.getEntityStart()));

  return entities;
}
