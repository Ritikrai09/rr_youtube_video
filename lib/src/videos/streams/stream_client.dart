import 'dart:collection';
import 'dart:developer';
import 'dart:isolate';

import 'package:logging/logging.dart';

import '../../exceptions/exceptions.dart';
import '../../extensions/helpers_extension.dart';
import '../../js/js_engine.dart';
import '../../retry.dart';
import '../../reverse_engineering/heuristics.dart';
import '../../reverse_engineering/models/stream_info_provider.dart';
import '../../reverse_engineering/pages/watch_page.dart';
import '../../reverse_engineering/player/player_response.dart';
import '../../reverse_engineering/youtube_http_client.dart';
import '../video_id.dart';
import '../youtube_api_client.dart';
import 'stream_controller.dart';
import 'streams.dart';

/// Queries related to media streams of YouTube videos.
class StreamClient {
  static final _logger = Logger('YoutubeExplode.StreamsClient');
  final YoutubeHttpClient _httpClient;
  final StreamController _controller;

  /// Initializes an instance of [StreamClient]
  StreamClient(this._httpClient) : _controller = StreamController(_httpClient);

  /// Gets the manifest that contains information
  /// about available streams in the specified video.
  ///
  /// See [YoutubeApiClient] for all the possible clients that can be set using the [ytClients] parameter.
  /// If [ytClients] is null the library automatically manages the clients, otherwise only the clients provided are used.
  /// Currently by default the [YoutubeApiClient.android] and [YoutubeApiClient.ios] clients are used, if the extraction fails the [YoutubeApiClient.tvSimplyEmbedded] client is used instead.
  ///
  /// If [requireWatchPage] (default: true) is set to false the watch page is not used to extract the streams (so the process can be faster) but
  /// it COULD be less reliable (not tested thoroughly).
  /// If the extracted streams require signature decoding for which the watch page is required, the client will automatically fetch the watch page anyways (e.g. [YoutubeApiClient.tvSimplyEmbedded]).
  ///
  /// If the extraction fails an exception is thrown, to diagnose the issue enable the logging from the `logging` package, and open an issue with the output.
  /// For example:
  /// ```dart
  /// Logger.root.level = Level.FINER;
  /// Logger.root.onRecord.listen(print);
  /// // run yt related code ...
  ///
  /// ```
  Future<StreamManifest> getManifest(dynamic videoId,
      {@Deprecated(
          'Use the ytClient parameter instead passing the proper [YoutubeApiClient]s')
      bool fullManifest = false,
      List<YoutubeApiClient>? ytClients,
      bool requireWatchPage = true}) async {
    videoId = VideoId.fromString(videoId);
    final clients =
        ytClients ?? [YoutubeApiClient.ios, YoutubeApiClient.android];

    final uniqueStreams = LinkedHashSet<StreamInfo>(
      equals: (a, b) {
        if (a.runtimeType != b.runtimeType) return false;
        if (a is AudioStreamInfo && b is AudioStreamInfo) {
          return a.tag == b.tag && a.audioTrack == b.audioTrack;
        }
        return a.tag == b.tag;
      },
      hashCode: (e) {
        if (e is AudioStreamInfo) {
          return e.tag.hashCode ^ e.audioTrack.hashCode;
        }
        return e.tag.hashCode;
      },
    );

    Object? lastException;

    for (final client in clients) {
      _logger.fine(
          'Getting stream manifest for video $videoId with client: ${client.payload['context']['client']['clientName']}');
      try {
        await retry(_httpClient, () async {
          final streams = await _getStreams(videoId,
                  ytClient: client, requireWatchPage: requireWatchPage)
              .toList();
          if (streams.isEmpty) {
            throw VideoUnavailableException(
              'Video "$videoId" does not contain any playable streams.',
            );
          }

          final response = await _httpClient.head(streams.first.url);
          if (response.statusCode == 403) {
            throw YoutubeExplodeException(
              'Video $videoId returned 403 (stream: ${streams.first.tag})',
            );
          }
          uniqueStreams.addAll(streams);
        });
      } catch (e, s) {
        _logger.severe(
            'Failed to get stream manifest for video $videoId with client: ${client.payload['context']['client']['clientName']}. Reason: $e\n',
            e,
            s);
        lastException = e;
      }
    }

    // If the user has not provided any client retry with the tvSimplyEmbedded client, which works also in some restricted videos.
    if (uniqueStreams.isEmpty && ytClients == null) {
      return getManifest(videoId,
          ytClients: [YoutubeApiClient.tvSimplyEmbedded]);
    }
    if (uniqueStreams.isEmpty) {
      throw lastException ??
          VideoUnavailableException(
              'Video "$videoId" has no available streams');
    }
    return StreamManifest(uniqueStreams.toList());
  }

  /// Gets the HTTP Live Stream (HLS) manifest URL
  /// for the specified video (if it's a live video stream).
  Future<String> getHttpLiveStreamUrl(VideoId videoId) async {
    final watchPage = await WatchPage.get(_httpClient, videoId.value);

    final playerResponse = watchPage.playerResponse;

    if (playerResponse == null) {
      throw TransientFailureException(
        "Couldn't extract the playerResponse from the Watch Page!",
      );
    }

    if (!playerResponse.isVideoPlayable) {
      throw VideoUnplayableException.unplayable(
        videoId,
        reason: playerResponse.videoPlayabilityError ?? '',
      );
    }

    final hlsManifest = playerResponse.hlsManifestUrl;
    if (hlsManifest == null) {
      throw VideoUnplayableException.notLiveStream(videoId);
    }
    return hlsManifest;
  }

  /// Gets the actual stream which is identified by the specified metadata.
  /// Usually this downloads the bytes of the stream.
  /// For HLS streams all the fragments are concatenated into a single stream.
  Stream<List<int>> get(StreamInfo streamInfo) =>
      _httpClient.getStream(streamInfo, streamClient: this);

  Stream<StreamInfo> _getStreams(VideoId videoId,
      {required YoutubeApiClient ytClient,
      required bool requireWatchPage}) async* {
    // Use await for instead of yield* to catch exceptions
    await for (final stream
        in _getStream(videoId, ytClient, requireWatchPage)) {
      yield stream;
    }
  }

  Stream<StreamInfo> _getStream(VideoId videoId, YoutubeApiClient ytClient,
      bool requireWatchPage) async* {

    final watchPage = requireWatchPage
        ? await WatchPage.get(_httpClient, videoId.value)
        : null;
  
    //  log("ytClient.toJson().toString() ${ytClient.toJson().toString()}");

    final playerResponse = await _controller
        .getPlayerResponse(videoId, ytClient, watchPage: watchPage);

    //  final playerResponse = await Isolate.run<PlayerResponse>(
    //   () async {
        
    //     var data = await _controller
    //     .getPlayerResponse(videoId, ytClient, watchPage: watchPage);

    //     return data;
    //   },
    //   /* Send necessary data here, possibly wrapped in a custom class or map */
    // );
    //  final receivePort = ReceivePort(); // Create a receive port

      // Spawn the isolate
      // await Isolate.spawn(_isolateSendPlayerResponse, receivePort.sendPort);

      // Wait for the isolate to send back its send port
      // final sendPort = await receivePort.first as SendPort;

      // Send parameters to the isolate
      // sendPort.send([
      //   {
      //     'videoId': videoId,
      //     'ytClient': ytClient, // Ensure ytClient is serializable
      //     'watchPage': watchPage,
      //   },
      // ]);

    //  await for (final playerResponse in receivePort) {
    // // If the result is a List<StreamInfo>
    // if (playerResponse is PlayerResponse) {

    if (!playerResponse.previewVideoId.isNullOrWhiteSpace) {
      throw VideoRequiresPurchaseException.preview(
        videoId,
        VideoId(playerResponse.previewVideoId!),
      );
    }

    if (playerResponse.videoPlayabilityError?.contains('payment') ?? false) {
      throw VideoRequiresPurchaseException(videoId);
    }

    if (!playerResponse.isVideoPlayable) {
      throw VideoUnplayableException.unplayable(
        videoId,
        reason: playerResponse.videoPlayabilityError ?? '',
      );
    }

    yield* _parseStreamInfo(playerResponse.streams,
        watchPage: watchPage, videoId: videoId);

    if (!playerResponse.dashManifestUrl.isNullOrWhiteSpace) {
      final dashManifest =
          await _controller.getDashManifest(playerResponse.dashManifestUrl!);
      yield* _parseStreamInfo(dashManifest.streams,
          watchPage: watchPage, videoId: videoId);
    }
    if (!playerResponse.hlsManifestUrl.isNullOrWhiteSpace) {
      final hlsManifest =
          await _controller.getHlsManifest(playerResponse.hlsManifestUrl!);
      yield* _parseStreamInfo(hlsManifest.streams,
          watchPage: watchPage, videoId: videoId);
    }
    // }
    //  }
  }

Future<void> _isolateSendPlayerResponse(SendPort sendPort) async {
  
  final receivePort = ReceivePort();

  sendPort.send(receivePort.sendPort); // Send back the send port

  await for (final message in receivePort) {
    final params = message[0];
    final videoId = params['videoId'] as VideoId;
    final ytClient = params['ytClient'] as YoutubeApiClient;
    final requireWatchPage = params['watchPage'] as WatchPage;

    try {
      final streamInfoList = await _controller.getPlayerResponse(videoId, ytClient, watchPage:  requireWatchPage);
       log("spawn streamInfoList.toString()");
      log(streamInfoList.toString());
      sendPort.send(streamInfoList); // Send back the result
    } catch (e) {
      sendPort.send({'error': e.toString()}); // Send error back
    }
  }
}


  Future<String> _getDecipherFunction(WatchPage watchPage) async {
    final playerScript = await _httpClient.getString(watchPage.sourceUrl);
    final funcNameExp = RegExp(
        r'function\(\w+\)\{[^}]*\.slice\(0,0\).*?return\s?\w+?\.join\(""\)};',
        dotAll: true);
    final funcMatch = funcNameExp.firstMatch(playerScript);
    return funcMatch!.group(0)!.replaceFirst('function', 'function main');
  }

  final _sigCache = <String, String>{};

  Stream<StreamInfo> _parseStreamInfo(Iterable<StreamInfoProvider> streams,
      {WatchPage? watchPage, VideoId? videoId}) async* {
    assert(watchPage != null || videoId != null,
        'Either watchPage or videoId must be provided');
    String? funcCode;

    for (final stream in streams) {
      final itag = stream.tag;
      var url = Uri.parse(stream.url);

      if (url.queryParameters.containsKey('n')) {
        final nParam = url.queryParameters['n']!;
        late final String deciphered;
        if (_sigCache.containsKey(nParam)) {
          deciphered = _sigCache[nParam]!;
        } else {
          funcCode ??= await _getDecipherFunction(
              watchPage ??= await WatchPage.get(_httpClient, videoId!.value));
          deciphered = _sigCache[nParam] = JSEngine.run(funcCode, [nParam]);
          _logger.fine(
              'Deciphered signature: ${url.queryParameters['n']} -> $deciphered');
        }
        url = url.setQueryParam('n', deciphered);
      }

      final contentLength = stream.contentLength ??
          (await _httpClient.getContentLength(url, validate: false)) ??
          0;

      if (contentLength <= 0) {
        continue;
      }

      final container = StreamContainer.parse(stream.container!);
      final fileSize = FileSize(contentLength);
      final bitrate = Bitrate(stream.bitrate!);

      final audioCodec = stream.audioCodec;
      final videoCodec = stream.videoCodec;

      // HLS
      if (stream.source == StreamSource.hls) {
        if (stream.audioOnly) {
          yield HlsAudioStreamInfo(
            videoId ?? watchPage!.videoId,
            itag,
            url,
            container,
            fileSize,
            bitrate,
            '',
            '',
            stream.codec,
          );
          continue;
        }

        final framerate = Framerate(stream.framerate ?? 24);
        // TODO: Implement quality from itag
        final videoQuality = VideoQualityUtil.fromLabel(stream.qualityLabel);
        final videoWidth = stream.videoWidth;
        final videoHeight = stream.videoHeight;
        final videoResolution = videoWidth != null && videoHeight != null
            ? VideoResolution(videoWidth, videoHeight)
            : videoQuality.toVideoResolution();

        if (stream.videoOnly) {
          yield HlsVideoStreamInfo(
            videoId ?? watchPage!.videoId,
            itag,
            url,
            container,
            fileSize,
            bitrate,
            videoCodec ?? '',
            videoQuality.qualityString,
            videoQuality,
            videoResolution,
            framerate,
            stream.codec,
            0,
          );
        } else {
          yield HlsMuxedStreamInfo(
            videoId ?? watchPage!.videoId,
            itag,
            url,
            container,
            fileSize,
            bitrate,
            audioCodec!,
            videoCodec!,
            videoQuality.qualityString,
            videoQuality,
            videoResolution,
            framerate,
            stream.codec,
          );
        }
        continue;
      }

      // Muxed or Video-only
      if (!videoCodec.isNullOrWhiteSpace) {
        final framerate = Framerate(stream.framerate ?? 24);
        // TODO: Implement quality from itag
        final videoQuality = VideoQualityUtil.fromLabel(stream.qualityLabel);

        final videoWidth = stream.videoWidth;
        final videoHeight = stream.videoHeight;
        final videoResolution = videoWidth != null && videoHeight != null
            ? VideoResolution(videoWidth, videoHeight)
            : videoQuality.toVideoResolution();

        // Muxed
        if (!audioCodec.isNullOrWhiteSpace &&
            stream.source != StreamSource.adaptive) {
          assert(stream.audioTrack == null);
          yield MuxedStreamInfo(
            videoId ?? watchPage!.videoId,
            itag,
            url,
            container,
            fileSize,
            bitrate,
            audioCodec!,
            videoCodec!,
            videoQuality.qualityString,
            videoQuality,
            videoResolution,
            framerate,
            stream.codec,
          );
          continue;
        }

        // Video only
        yield VideoOnlyStreamInfo(
          videoId ?? watchPage!.videoId,
          itag,
          url,
          container,
          fileSize,
          bitrate,
          videoCodec!,
          videoQuality.qualityString,
          videoQuality,
          videoResolution,
          framerate,
          stream.fragments ?? const [],
          stream.codec,
        );
        continue;
        // Audio-only
      } else if (!audioCodec.isNullOrWhiteSpace) {
        yield AudioOnlyStreamInfo(
            videoId ?? watchPage!.videoId,
            itag,
            url,
            container,
            fileSize,
            bitrate,
            audioCodec!,
            stream.qualityLabel!,
            stream.fragments ?? const [],
            stream.codec,
            stream.audioTrack);
      } else {
        throw YoutubeExplodeException('Could not extract stream codec');
      }
    }
  }
}
