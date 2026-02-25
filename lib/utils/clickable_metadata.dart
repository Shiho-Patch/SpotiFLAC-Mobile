import 'package:flutter/material.dart';
import 'package:spotiflac_android/services/platform_bridge.dart';
import 'package:spotiflac_android/screens/artist_screen.dart';
import 'package:spotiflac_android/screens/album_screen.dart';
import 'package:spotiflac_android/screens/home_tab.dart'
    show ExtensionArtistScreen, ExtensionAlbumScreen;
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('ClickableMetadata');

/// Navigate to an artist screen by searching Deezer for the artist ID.
///
/// If [artistId] is provided and valid, navigates directly.
/// Otherwise, searches Deezer by [artistName] to resolve the ID first.
/// For extension-based content, pass [extensionId] to use ExtensionArtistScreen.
Future<void> navigateToArtist(
  BuildContext context, {
  required String artistName,
  String? artistId,
  String? coverUrl,
  String? extensionId,
}) async {
  if (artistName.isEmpty) return;

  // If we have a valid artist ID already, navigate directly
  if (artistId != null &&
      artistId.isNotEmpty &&
      artistId != 'unknown' &&
      artistId != 'deezer:unknown') {
    _pushArtistScreen(context,
        artistId: artistId,
        artistName: artistName,
        coverUrl: coverUrl,
        extensionId: extensionId);
    return;
  }

  // If it's extension-based content without an ID, can't search Deezer for it
  if (extensionId != null) {
    _showUnavailable(context, 'Artist');
    return;
  }

  // Search Deezer to resolve the artist ID
  _showLoadingSnackBar(context, 'Looking up artist...');
  try {
    final results = await PlatformBridge.searchDeezerAll(
      artistName,
      trackLimit: 0,
      artistLimit: 3,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    final artistList = results['artists'] as List<dynamic>? ?? [];
    if (artistList.isEmpty) {
      _showUnavailable(context, 'Artist');
      return;
    }

    // Find best match - prefer exact name match (case-insensitive)
    Map<String, dynamic>? bestMatch;
    final lowerName = artistName.toLowerCase().trim();
    for (final a in artistList) {
      if (a is Map<String, dynamic>) {
        final name = (a['name'] as String? ?? '').toLowerCase().trim();
        if (name == lowerName) {
          bestMatch = a;
          break;
        }
      }
    }
    bestMatch ??= artistList.first as Map<String, dynamic>;

    final resolvedId = bestMatch['id'] as String? ?? '';
    final resolvedName = bestMatch['name'] as String? ?? artistName;
    final resolvedImage = bestMatch['images'] as String?;

    if (resolvedId.isEmpty) {
      _showUnavailable(context, 'Artist');
      return;
    }

    if (!context.mounted) return;
    _pushArtistScreen(context,
        artistId: resolvedId,
        artistName: resolvedName,
        coverUrl: resolvedImage ?? coverUrl);
  } catch (e) {
    _log.e('Failed to look up artist "$artistName": $e', e);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    _showUnavailable(context, 'Artist');
  }
}

/// Navigate to an album screen by searching Deezer for the album ID.
///
/// If [albumId] is provided and valid, navigates directly.
/// Otherwise, searches Deezer by [albumName] (optionally with [artistName]) to resolve the ID.
/// For extension-based content, pass [extensionId] to use ExtensionAlbumScreen.
Future<void> navigateToAlbum(
  BuildContext context, {
  required String albumName,
  String? albumId,
  String? artistName,
  String? coverUrl,
  String? extensionId,
}) async {
  if (albumName.isEmpty) return;

  // If we have a valid album ID already, navigate directly
  if (albumId != null &&
      albumId.isNotEmpty &&
      albumId != 'unknown' &&
      albumId != 'deezer:unknown') {
    _pushAlbumScreen(context,
        albumId: albumId,
        albumName: albumName,
        coverUrl: coverUrl,
        extensionId: extensionId);
    return;
  }

  // If it's extension-based content without an ID, can't search Deezer for it
  if (extensionId != null) {
    _showUnavailable(context, 'Album');
    return;
  }

  // Search Deezer to resolve the album ID
  _showLoadingSnackBar(context, 'Looking up album...');
  try {
    // Build search query: "albumName artistName" for better accuracy
    final query = artistName != null && artistName.isNotEmpty
        ? '$albumName $artistName'
        : albumName;

    final results = await PlatformBridge.searchDeezerAll(
      query,
      trackLimit: 0,
      artistLimit: 0,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    final albumList = results['albums'] as List<dynamic>? ?? [];
    if (albumList.isEmpty) {
      _showUnavailable(context, 'Album');
      return;
    }

    // Find best match - prefer exact name match (case-insensitive)
    Map<String, dynamic>? bestMatch;
    final lowerName = albumName.toLowerCase().trim();
    for (final a in albumList) {
      if (a is Map<String, dynamic>) {
        final name = (a['name'] as String? ?? '').toLowerCase().trim();
        if (name == lowerName) {
          bestMatch = a;
          break;
        }
      }
    }
    bestMatch ??= albumList.first as Map<String, dynamic>;

    final resolvedId = bestMatch['id'] as String? ?? '';
    final resolvedName = bestMatch['name'] as String? ?? albumName;
    final resolvedImage = bestMatch['images'] as String?;

    if (resolvedId.isEmpty) {
      _showUnavailable(context, 'Album');
      return;
    }

    if (!context.mounted) return;
    _pushAlbumScreen(context,
        albumId: resolvedId,
        albumName: resolvedName,
        coverUrl: resolvedImage ?? coverUrl);
  } catch (e) {
    _log.e('Failed to look up album "$albumName": $e', e);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    _showUnavailable(context, 'Album');
  }
}

void _pushArtistScreen(
  BuildContext context, {
  required String artistId,
  required String artistName,
  String? coverUrl,
  String? extensionId,
}) {
  if (extensionId != null) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ExtensionArtistScreen(
          extensionId: extensionId,
          artistId: artistId,
          artistName: artistName,
          coverUrl: coverUrl,
        ),
      ),
    );
  } else {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ArtistScreen(
          artistId: artistId,
          artistName: artistName,
          coverUrl: coverUrl,
        ),
      ),
    );
  }
}

void _pushAlbumScreen(
  BuildContext context, {
  required String albumId,
  required String albumName,
  String? coverUrl,
  String? extensionId,
}) {
  if (extensionId != null) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ExtensionAlbumScreen(
          extensionId: extensionId,
          albumId: albumId,
          albumName: albumName,
          coverUrl: coverUrl,
        ),
      ),
    );
  } else {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AlbumScreen(
          albumId: albumId,
          albumName: albumName,
          coverUrl: coverUrl,
          tracks: const [],
        ),
      ),
    );
  }
}

void _showLoadingSnackBar(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Text(message),
        ],
      ),
      duration: const Duration(seconds: 10),
    ),
  );
}

void _showUnavailable(BuildContext context, String type) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('$type information not available')),
  );
}

/// A reusable widget that makes text tappable to navigate to an artist screen.
///
/// Wraps the text in a GestureDetector that, when tapped, looks up the artist
/// via Deezer search and navigates to the ArtistScreen.
class ClickableArtistName extends StatelessWidget {
  final String artistName;
  final String? artistId;
  final String? coverUrl;
  final String? extensionId;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  const ClickableArtistName({
    super.key,
    required this.artistName,
    this.artistId,
    this.coverUrl,
    this.extensionId,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => navigateToArtist(
        context,
        artistName: artistName,
        artistId: artistId,
        coverUrl: coverUrl,
        extensionId: extensionId,
      ),
      child: Text(
        artistName,
        style: style,
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign,
      ),
    );
  }
}

/// A reusable widget that makes text tappable to navigate to an album screen.
///
/// Wraps the text in a GestureDetector that, when tapped, looks up the album
/// via Deezer search and navigates to the AlbumScreen.
class ClickableAlbumName extends StatelessWidget {
  final String albumName;
  final String? albumId;
  final String? artistName;
  final String? coverUrl;
  final String? extensionId;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  const ClickableAlbumName({
    super.key,
    required this.albumName,
    this.albumId,
    this.artistName,
    this.coverUrl,
    this.extensionId,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => navigateToAlbum(
        context,
        albumName: albumName,
        albumId: albumId,
        artistName: artistName,
        coverUrl: coverUrl,
        extensionId: extensionId,
      ),
      child: Text(
        albumName,
        style: style,
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign,
      ),
    );
  }
}
