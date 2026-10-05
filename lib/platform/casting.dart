import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import '../domain/models.dart';
import 'provider_client.dart';
import 'cast_session.dart';

typedef CastNetworkAddress = ({String name, InternetAddress address});

InternetAddress selectCastAddress(
  List<CastNetworkAddress> addresses, {
  InternetAddress? route,
}) {
  final candidates = addresses
      .where(
        (item) =>
            item.address.type == InternetAddressType.IPv4 &&
            !item.address.isLoopback &&
            !item.address.isMulticast &&
            item.address.address != '0.0.0.0' &&
            !RegExp(
              r'^(utun|tun|tap|ipsec|ppp|wg|tailscale|pdp_ip|rmnet|ccmni|docker|veth|br-)|vpn',
              caseSensitive: false,
            ).hasMatch(item.name),
      )
      .toList();
  for (final item in candidates) {
    if (item.address.address == route?.address) return item.address;
  }
  int priority(String name) {
    name = name.toLowerCase();
    if (name == 'en0' ||
        name.startsWith('wlan') ||
        name.startsWith('wlp') ||
        name.contains('wi-fi') ||
        name.contains('wifi')) {
      return 2;
    }
    if (name.startsWith('en') || name.startsWith('eth')) return 1;
    return 0;
  }

  candidates.sort((a, b) => priority(b.name).compareTo(priority(a.name)));
  if (candidates.isEmpty) {
    throw const ProviderException('未找到可供电视访问的局域网地址，请连接同一 Wi-Fi');
  }
  return candidates.first.address;
}

Future<InternetAddress> _castAddress(Uri? receiver) async {
  final networks = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
  );
  InternetAddress? route;
  if (receiver != null) {
    try {
      final socket = await Socket.connect(
        receiver.host,
        receiver.port,
        timeout: const Duration(seconds: 2),
      );
      route = socket.address;
      socket.destroy();
    } catch (_) {
      // The normal control request will report a receiver connection failure.
    }
  }
  return selectCastAddress([
    for (final network in networks)
      for (final address in network.addresses)
        (name: network.name, address: address),
  ], route: route);
}

/// A per-session relay. Only registered media resources are exposed; there is no
/// arbitrary URL parameter or filesystem route. Closed when casting ends.
class CastRelay implements CastRelayHandle, CastRelayDiagnostics {
  CastRelay({Future<InternetAddress> Function(Uri?)? addressResolver})
    : _addressResolver = addressResolver ?? _castAddress;
  final Future<InternetAddress> Function(Uri?) _addressResolver;
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
  bool mediaRequested = false;
  @override
  int bytesSent = 0;
  @override
  String? transferError;
  @override
  Future<String> start(
    ResolvedMedia media,
    String? local, {
    Uri? receiver,
  }) async {
    if (_closed || _server != null) throw StateError('投屏会话已关闭或已启动');
    if (local != null &&
        (!await File(local).exists() || await File(local).length() == 0)) {
      throw const ProviderException('本地视频不可读取，请重新准备视频');
    }
    final address = await _addressResolver(receiver);
    if (_closed) throw StateError('投屏会话已关闭');
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    if (_closed) {
      await server.close(force: true);
      throw StateError('投屏会话已关闭');
    }
    _server = server;
    _base = 'http://${address.address}:${_server!.port}/$_token/';
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
        'Range, Content-Type, getcontentFeatures.dlna.org, transferMode.dlna.org',
      );
      request.response.headers.set(
        'Access-Control-Expose-Headers',
        'Content-Length, Content-Range, Accept-Ranges, contentFeatures.dlna.org, transferMode.dlna.org',
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
      if (request.method == 'GET') mediaRequested = true;
      transferError = null;
      request.response.headers.set('transferMode.dlna.org', 'Streaming');
      if (_local != null && key == '0') {
        final file = File(_local!);
        final size = await file.length();
        var start = 0, end = size - 1;
        final range = request.headers.value('range');
        // HEAD describes the full representation. Unknown or multiple ranges
        // may be ignored; single byte ranges include end-relative requests.
        if (request.method == 'GET' &&
            range != null &&
            range.startsWith('bytes=') &&
            !range.contains(',')) {
          final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range.trim());
          if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) {
            start = size;
          } else if (match[1]!.isEmpty) {
            final suffix = BigInt.parse(match[2]!);
            final remaining = BigInt.from(size) - suffix;
            start = suffix == BigInt.zero
                ? size
                : remaining.isNegative
                ? 0
                : remaining.toInt();
          } else {
            final first = BigInt.parse(match[1]!);
            start = first > BigInt.from(size) ? size : first.toInt();
            if (match[2]!.isNotEmpty) {
              final last = BigInt.parse(match[2]!);
              end = last > BigInt.from(end) ? end : last.toInt();
            }
          }
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
        request.response.headers.set(
          'contentFeatures.dlna.org',
          'DLNA.ORG_OP=01',
        );
        request.response.contentLength = max(0, end - start + 1);
        if (request.method != 'HEAD') {
          await request.response.addStream(
            _count(file.openRead(start, end + 1)),
          );
        }
        return;
      }
      final outgoing = http.Request(request.method, remote)
        ..headers.addAll(_headers)
        ..headers['Accept-Encoding'] = 'identity';
      if (request.headers.value('range') case final range?) {
        outgoing.headers['Range'] = range;
      }
      final response = await _client
          .send(outgoing)
          .timeout(const Duration(seconds: 25));
      request.response.statusCode = response.statusCode;
      if (response.statusCode >= 400) {
        transferError = '视频源返回 ${response.statusCode}，请重新获取视频后投屏';
      }
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
        await request.response.addStream(_count(response.stream));
      }
    } catch (problem) {
      if (!_closed) {
        transferError = problem is FileSystemException
            ? '本地视频读取失败，请重新准备视频'
            : '视频传输中断，请检查手机网络后重试';
      }
      try {
        request.response.statusCode = 502;
      } catch (_) {}
    } finally {
      try {
        await request.response.close();
      } catch (_) {
        /* Receiver may close a probe early. */
      }
    }
  }

  Stream<List<int>> _count(Stream<List<int>> stream) => stream.map((bytes) {
    bytesSent += bytes.length;
    return bytes;
  });

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

class DlnaCommandException extends ProviderException {
  const DlnaCommandException(this.action, this.code)
    : super('电视未完成 $action 操作（DLNA $code）');
  final String action;
  final int? code;
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
    if (response.bodyBytes.length > 128 * 1024) {
      throw const FormatException('电视状态响应超过限制');
    }
    XmlDocument document;
    try {
      document = XmlDocument.parse(response.body);
    } catch (_) {
      throw const ProviderException('电视返回的 DLNA 响应无效');
    }
    final elements = document.descendants.whereType<XmlElement>();
    if (elements.any((element) => element.name.local == 'Fault')) {
      final code = elements
          .where((element) => element.name.local == 'errorCode')
          .firstOrNull
          ?.innerText;
      throw DlnaCommandException(action, int.tryParse(code ?? ''));
    }
    if (response.statusCode >= 300) {
      throw const ProviderException('电视未接受播放操作，请检查接收端是否支持 DLNA');
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
