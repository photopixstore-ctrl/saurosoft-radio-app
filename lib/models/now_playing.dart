class NowPlaying {
  final String artist;
  final String title;
  final String? coverArtUrl;

  const NowPlaying({
    required this.artist,
    required this.title,
    this.coverArtUrl,
  });

  factory NowPlaying.empty() => const NowPlaying(artist: '', title: '');

  factory NowPlaying.fromJson(Map<String, dynamic> json) {
    return NowPlaying(
      artist: (json['artist'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      coverArtUrl: json['cover'] as String?,
    );
  }
}
