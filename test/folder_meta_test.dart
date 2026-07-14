/*
 * data/meta.json — the listing a shared folder carries about itself.
 *
 * The file arrives from a STRANGER'S folder, so most of what matters here is
 * what happens when it is hostile or simply wrong: the parse must clamp, refuse,
 * and carry on, because it runs in the middle of a folder sync and a throw there
 * would take the sync down with it.
 */

import 'dart:convert';

import 'package:aurora/services/folders/folder_meta.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('round-trips a normal listing', () {
    const src = '''
    {
      "title": "Big Buck Bunny",
      "desc": "A large rabbit deals with three bullies.",
      "cat": "film",
      "tags": ["1080p", "animation", "open"],
      "adult": false,
      "cover": "cover.jpg",
      "banner": "banner.png",
      "trailer": "trailer.webm",
      "gallery": ["media1.png", "media2.jpg", "media3.webm"]
    }''';
    final m = FolderMeta.parse(src);
    expect(m.title, 'Big Buck Bunny');
    expect(m.cat, 'film');
    expect(m.adult, isFalse);
    expect(m.tags, ['1080p', 'animation', 'open']);
    expect(m.cover, 'cover.jpg');
    expect(m.trailer, 'trailer.webm');
    expect(m.gallery, ['media1.png', 'media2.jpg', 'media3.webm']);

    // Re-encode → re-parse gives the same listing.
    final again = FolderMeta.parse(m.encode());
    expect(again.title, m.title);
    expect(again.cat, m.cat);
    expect(again.tags, m.tags);
    expect(again.gallery, m.gallery);
  });

  test('clamps a hostile listing instead of throwing', () {
    final src = jsonEncode({
      'title': 'T' * 5000,
      'desc': 'D' * 9000,
      'cat': '../etc/passwd',
      'tags': [for (var i = 0; i < 50; i++) 'tag$i'],
      'gallery': [for (var i = 0; i < 40; i++) 'media$i.png'],
    });
    final m = FolderMeta.parse(src);
    expect(m.title.length, kMetaTitleMax);
    expect(m.desc.length, kMetaDescMax);
    // An unknown category is not "trusted because it was written down".
    expect(m.cat, kFolderCategoryFallback);
    expect(m.tags.length, kMetaTagsMax);
    expect(m.gallery.length, kMetaGalleryMax);
  });

  test('a media name can never climb out of data/', () {
    // This is the security boundary: these names are about to be joined onto a
    // real directory that also holds the folder's MASTER KEY (.folder.json).
    for (final bad in [
      '../../.folder.json',
      '../secret.png',
      '/etc/passwd.png',
      'sub/dir/cover.jpg',
      r'..\windows\evil.png',
      '.folder.json',
      '.hidden.png',
    ]) {
      final m = FolderMeta.parse(jsonEncode({'cover': bad, 'gallery': [bad]}));
      expect(m.cover, isNull, reason: 'cover accepted "$bad"');
      expect(m.gallery, isEmpty, reason: 'gallery accepted "$bad"');
    }
  });

  test('only images and videos are media; a cover is an image, a trailer a video',
      () {
    final m = FolderMeta.parse(jsonEncode({
      'cover': 'cover.exe', // not an image
      'banner': 'banner.mp3', // audio is not artwork
      'trailer': 'trailer.png', // a still is not a trailer
      'gallery': ['ok1.png', 'notes.txt', 'clip.webm', 'song.flac'],
    }));
    expect(m.cover, isNull);
    expect(m.banner, isNull);
    expect(m.trailer, isNull);
    expect(m.gallery, ['ok1.png', 'clip.webm']);
  });

  test('garbage is an empty listing, not an exception', () {
    for (final junk in ['', 'not json', '[]', 'null', '{{{', '42']) {
      final m = FolderMeta.parse(junk);
      expect(m.isEmpty, isTrue, reason: 'junk "$junk" produced a listing');
      expect(m.cat, kFolderCategoryFallback);
    }
  });

  test('a future publisher\'s unknown keys survive an older client rewriting it',
      () {
    final m = FolderMeta.parse(jsonEncode({
      'title': 'Thing',
      'cat': 'game',
      'imdb': 'tt0123456', // we do not know this key
      'year': 2031,
    }));
    final out = jsonDecode(m.encode()) as Map<String, dynamic>;
    expect(out['imdb'], 'tt0123456');
    expect(out['year'], 2031);
    expect(out['title'], 'Thing');
    expect(out['cat'], 'game');
  });

  test('+18 is a flag, so an adult film is still a film', () {
    final m = FolderMeta.parse(jsonEncode({'cat': 'film', 'adult': true}));
    expect(m.cat, 'film'); // a category filter still finds it
    expect(m.adult, isTrue); // and an adult filter can hide it
  });

  test('tags survive the comma-separated wire form the op-log uses', () {
    const m = FolderMeta(tags: ['1080p', 'scifi', 'open']);
    expect(m.tagsWire, '1080p, scifi, open');
    expect(FolderMeta.tagsFromWire(m.tagsWire), ['1080p', 'scifi', 'open']);
    // Duplicates and empties collapse.
    expect(FolderMeta.tagsFromWire('a,,a,  b '), ['a', 'b']);
  });

  test('every category is lowercase and unique, and other is the fallback', () {
    expect(kFolderCategories.toSet().length, kFolderCategories.length);
    for (final c in kFolderCategories) {
      expect(c, c.toLowerCase());
      expect(FolderMeta.parse(jsonEncode({'cat': c})).cat, c);
    }
    expect(kFolderCategories.contains(kFolderCategoryFallback), isTrue);
  });
}
