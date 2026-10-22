import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';

void main() {
  late HttpServer server;
  late DioHttpClient client;
  late int closedPort;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response
        ..write('ok')
        ..close();
    });

    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    closedPort = probe.port;
    await probe.close();

    client = DioHttpClient(timeout: const Duration(seconds: 5), userAgent: 'test', debug: false)
      ..setProxyPort(closedPort);
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('falls back to a direct connection when the proxy port is closed', () async {
    final response = await client.get<String>('http://127.0.0.1:${server.port}/');

    expect(response.statusCode, 200);
    expect(response.data, 'ok');
  });

  test('proxy-only requests do not fall back to a direct connection', () async {
    await expectLater(
      client.get<String>('http://127.0.0.1:${server.port}/', proxyOnly: true),
      throwsA(isA<Exception>()),
    );
  });
}
