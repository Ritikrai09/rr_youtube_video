

import 'channels/channels.dart';
import 'playlists/playlist_client.dart';
import 'reverse_engineering/player/player_response.dart';
import 'reverse_engineering/youtube_http_client.dart';
import 'search/search_client.dart';
import 'videos/video_client.dart';
import 'package:http/http.dart' as http;

/// Library entry point.
class YoutubeExplode {
  final YoutubeHttpClient _httpClient;

  /// Queries related to YouTube videos.
  late final VideoClient videos;

  /// Queries related to YouTube playlists.
  late final PlaylistClient playlists;

  /// Queries related to YouTube channels.
  late final ChannelClient channels;

  /// YouTube search queries.
  late final SearchClient search;

  /// Initializes an instance of [YoutubeClient].
  YoutubeExplode([YoutubeHttpClient? httpClient])
      : _httpClient = httpClient ?? YoutubeHttpClient() {
    videos = VideoClient(_httpClient);
    playlists = PlaylistClient(_httpClient);
    channels = ChannelClient(_httpClient);
    search = SearchClient(_httpClient);
  }

  /// Closes the HttpClient assigned to this [YoutubeHttpClient].
  /// Should be called after this is not used anymore.
  void close() => _httpClient.close();
}

class YouTubeService {
  final String apiKey;

  YouTubeService(this.apiKey);

  Future<PlayerResponse> fetchVideoDetails(String videoId) async {
    final url =
        'https://www.googleapis.com/youtube/v3/videos?part=snippet,contentDetails&id=$videoId&key=$apiKey';

    final response = await http.get(Uri.parse(url));

    if (response.statusCode == 200) {
      // final data = json.decode(response.body);
      // if (data['items'].isNotEmpty) {
      //   return data['items'][0];
      // }
      return PlayerResponse.parse(response.body);
    }
    return PlayerResponse.parse(response.body);
  }
}