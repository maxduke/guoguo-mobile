import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import '../domain/models.dart';
import 'provider_client.dart';
import 'cast_session.dart';

/// A per-session relay. Only registered media resources are exposed; there is no
/// arbitrary URL parameter or filesystem route. Closed when casting ends.
class CastRelay implements CastRelayHandle {
  HttpServer? _server;
  final http.Client _client = http.Client();
  final Map<String, Uri> _resources = {};
  final String _token = List.generate(
    24,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  String? _local;
  bool _closed = false;
  Future<void>? _closing;
  Map<String, String> _headers = {};
  late String _base;
  @override
  Future<String> start(ResolvedMedia media, String? local) async {
    if (_closed || _server != null) throw StateError('投屏会话已关闭或已启动');
    final networks = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    final candidates = networks
        .expand((n) => n.addresses)
        .where(
          (a) =>
              a.address.startsWith('192.168.') ||
              a.address.startsWith('10.') ||
              (a.rawAddress[0] == 172 &&
                  a.rawAddress[1] >= 16 &&
                  a.rawAddress[1] <= 31),
        )
        .toList();
    if (candidates.isEmpty) throw const ProviderException('请将手机与电视连接到同一 Wi-Fi');
    if (_closed) throw StateError('投屏会话已关闭');
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    if (_closed) {
      await server.close(force: true);
      throw StateError('投屏会话已关闭');
    }
    _server = server;
    _base = 'http://${candidates.first.address}:${_server!.port}/$_token/';
    _local = local;
    _headers = media.headers;
    _resources['0'] = Uri.parse(media.url);
    _server!.listen((request) => unawaited(_serve(request)));
    return '${_base}0${media.hls && local == null ? '.m3u8' : '.mp4'}';
  }

  Future<void> _serve(HttpRequest request) async {
    try {
      if (_closed) {
        request.response.statusCode = 410;
        return;
      }
      request.response.headers.set('Access-Control-Allow-Origin', '*');
      request.response.headers.set(
        'Access-Control-Allow-Headers',
        'Range, Content-Type',
      );
      request.response.headers.set(
        'Access-Control-Expose-Headers',
        'Content-Length, Content-Range, Accept-Ranges',
      );
      if (request.method == 'OPTIONS') {
        request.response.statusCode = 204;
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        request.response.statusCode = 405;
        return;
      }
      final parts = request.uri.pathSegments;
      if (parts.length != 2 || parts[0] != _token) {
        request.response.statusCode = 404;
        return;
      }
      final key = parts[1].split('.').first;
      final remote = _resources[key];
      if (remote == null) {
        request.response.statusCode = 404;
        return;
      }
      if (_local != null && key == '0') {
        final file = File(_local!);
        final size = await file.length();
        var start = 0, end = size - 1;
        final range = request.headers.value('range');
        if (range != null) {
          final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
          if (match == null) {
            request.response.statusCode = 416;
            return;
          }
          start = int.parse(match[1]!);
          if (match[2]!.isNotEmpty) end = int.parse(match[2]!);
          end = min(end, size - 1);
          if (start > end || start >= size) {
            request.response.statusCode = 416;
            request.response.headers.set('Content-Range', 'bytes */$size');
            return;
          }
          request.response.statusCode = 206;
          request.response.headers.set(
            'Content-Range',
            'bytes $start-$end/$size',
          );
        }
        request.response.headers.contentType = ContentType('video', 'mp4');
        request.response.headers.set('Accept-Ranges', 'bytes');
        request.response.contentLength = end - start + 1;
        if (request.method != 'HEAD') {
          await request.response.addStream(file.openRead(start, end + 1));
        }
        return;
      }
      final outgoing = http.Request(request.method, remote)
        ..headers.addAll(_headers);
      if (request.headers.value('range') case final range?) {
        outgoing.headers['Range'] = range;
      }
      final response = await _client
          .send(outgoing)
          .timeout(const Duration(seconds: 25));
      request.response.statusCode = response.statusCode;
      final contentType = response.headers['content-type'] ?? '';
      final playlist =
          remote.path.endsWith('.m3u8') || contentType.contains('mpegurl');
      if (playlist && request.method == 'GET' && response.statusCode == 200) {
        final raw = await response.stream.bytesToString();
        String reference(String path) {
          final target = remote.resolve(path);
          if (target.scheme != 'http' && target.scheme != 'https') {
            throw const FormatException('播放列表包含不支持的资源');
          }
          final id = '${_resources.length}';
          _resources[id] = target;
          return '$_base$id${target.path.endsWith('.m3u8') ? '.m3u8' : '.bin'}';
        }

        final rewritten = raw
            .split('\n')
            .map((line) {
              if (line.trim().isEmpty) return line;
              if (!line.startsWith('#')) return reference(line.trim());
              return line.replaceAllMapped(
                RegExp('URI="([^"]+)"'),
                (m) => 'URI="${reference(m[1]!)}"',
              );
            })
            .join('\n');
        request.response.headers.set(
          'Content-Type',
          'application/vnd.apple.mpegurl',
        );
        request.response.write(rewritten);
      } else {
        for (final header in [
          'content-type',
          'content-length',
          'content-range',
          'accept-ranges',
        ]) {
          if (response.headers[header] case final value?) {
            request.response.headers.set(header, value);
          }
        }
        await request.response.addStream(response.stream);
      }
    } catch (_) {
      try {
        request.response.statusCode = 502;
      } catch (_) {}
    } finally {
      await request.response.close();
    }
  }

  @override
  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    _client.close();
    _resources.clear();
    return _closing =
        _server?.close(force: true).then((_) {}) ?? Future.value();
  }
}

class DlnaDevice {
  DlnaDevice(this.name, this.control, this.serviceType, {this.client});
  final String name, serviceType;
  final Uri control;
  final http.Client? client;
  Future<Map<String, String>> command(
    String action,
    Map<String, String> parameters,
  ) async {
    final builder = XmlBuilder();
    builder.element(
      's:Envelope',
      namespaceUris: {'s': 'http://schemas.xmlsoap.org/soap/envelope/'},
      attributes: {
        's:encodingStyle': 'http://schemas.xmlsoap.org/soap/encoding/',
      },
      nest: () {
        builder.element(
          's:Body',
          nest: () => builder.element(
            'u:$action',
            namespaceUris: {'u': serviceType},
            nest: () {
              builder.element('InstanceID', nest: '0');
              parameters.forEach(
                (name, value) => builder.element(name, nest: value),
              );
            },
          ),
        );
      },
    );
    final response = await (client?.post ?? http.post)(
      control,
      headers: {
        'Content-Type': 'text/xml; charset="utf-8"',
        'SOAPAction': '"$serviceType#$action"',
      },
      body: builder.buildDocument().toXmlString(),
    ).timeout(const Duration(seconds: 10));
    if (response.statusCode >= 300) {
      throw const ProviderException('电视未接受播放操作，请检查接收端是否支持 DLNA');
    }
    if (response.bodyBytes.length > 128 * 1024) {
      throw const FormatException('电视状态响应超过限制');
    }
    final document = XmlDocument.parse(response.body);
    final elements = document.descendants.whereType<XmlElement>();
    if (elements.any((element) => element.name.local == 'Fault')) {
      throw const ProviderException('电视未支持或未完成此操作');
    }
    final result = elements
        .where((element) => element.name.local == '${action}Response')
        .firstOrNull;
    if (result == null) throw const FormatException('电视状态响应不完整');
    return {
      for (final element in result.childElements)
        element.name.local: element.innerText.trim(),
    };
  }

  Future<void> play(String url) async {
    await command('SetAVTransportURI', {
      'CurrentURI': url,
      'CurrentURIMetaData': '',
    });
    await command('Play', {'Speed': '1'});
  }
}

Future<List<DlnaDevice>> discoverDlna() async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final locations = <String>{};
  final subscription = socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    Datagram? packet;
    while ((packet = socket.receive()) != null) {
      final response = utf8.decode(packet!.data, allowMalformed: true);
      final match = RegExp(
        r'^location:\s*(.+)$',
        caseSensitive: false,
        multiLine: true,
      ).firstMatch(response);
      if (match != null) locations.add(match[1]!.trim());
    }
  });
  try {
    const query =
        'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n';
    socket.send(utf8.encode(query), InternetAddress('239.255.255.250'), 1900);
    await Future<void>.delayed(const Duration(seconds: 3));
  } finally {
    await subscription.cancel();
    socket.close();
  }
  final devices = <DlnaDevice>[];
  for (final location in locations.take(20)) {
    try {
      final uri = Uri.parse(location);
      if (uri.scheme != 'http' && uri.scheme != 'https') continue;
      final response = await http.get(uri).timeout(const Duration(seconds: 3));
      final document = XmlDocument.parse(response.body);
      for (final service in document.findAllElements('service')) {
        final type = service.getElement('serviceType')?.innerText ?? '';
        if (!type.contains(':AVTransport:')) continue;
        final control = service.getElement('controlURL')?.innerText;
        if (control == null) continue;
        devices.add(
          DlnaDevice(
            document.findAllElements('friendlyName').firstOrNull?.innerText ??
                'DLNA 电视',
            uri.resolve(control),
            type,
          ),
        );
      }
    } catch (_) {
      /* A malformed device must not hide other receivers. */
    }
  }
  return devices;
}
