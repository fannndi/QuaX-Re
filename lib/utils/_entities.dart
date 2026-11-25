import 'package:dart_twitter_api/twitter_api.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

abstract class Entity {
  List<int>? indices;

  Entity(this.indices);

  InlineSpan getContent();

  int getEntityStart() {
    return indices![0];
  }

  int getEntityEnd() {
    return indices![1];
  }
}

/// Monochrome links: the text keeps the body colour and the underline is the
/// affordance. A tinted link would reintroduce the accent this fork removed.
TextStyle _linkStyle(Color color) => TextStyle(
  color: color,
  decoration: TextDecoration.underline,
  decorationColor: color.withValues(alpha: 0.5),
);

class HashtagEntity extends Entity {
  final Hashtag hashtag;
  final Function onTap;
  final Color color;

  HashtagEntity(this.hashtag, this.onTap, this.color) : super(hashtag.indices);

  @override
  InlineSpan getContent() {
    return TextSpan(
      text: '#${hashtag.text}',
      style: _linkStyle(color),
      recognizer: TapGestureRecognizer()..onTap = () => onTap(),
    );
  }
}

class UserMentionEntity extends Entity {
  final UserMention mention;
  final Function onTap;
  final Color color;

  UserMentionEntity(this.mention, this.onTap, this.color)
    : super(mention.indices);

  @override
  InlineSpan getContent() {
    return TextSpan(
      text: '@${mention.screenName}',
      style: _linkStyle(color),
      recognizer: TapGestureRecognizer()..onTap = () => onTap(),
    );
  }
}

class UrlEntity extends Entity {
  final Url url;
  final Function onTap;
  final Color color;

  UrlEntity(this.url, this.onTap, this.color) : super(url.indices);

  @override
  InlineSpan getContent() {
    return TextSpan(
      text: url.displayUrl,
      style: _linkStyle(color),
      recognizer: TapGestureRecognizer()..onTap = () => onTap(),
    );
  }
}

class MediaEntity extends Entity {
  final Media media;

  MediaEntity(this.media) : super(media.indices);

  @override
  InlineSpan getContent() {
    return TextSpan(text: '');
  }
}
