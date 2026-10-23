import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/core/utils/exception_handler.dart';
import 'package:hiddify/features/proxy/model/ip_info_entity.dart' as oldipinfo;

import 'package:hiddify/features/proxy/model/proxy_failure.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';
import 'package:hiddify/utils/custom_loggers.dart';

abstract interface class ProxyRepository {
  // Stream<Either<ProxyFailure, List<OutboundGroup>>> watchProxies();
  Stream<Either<ProxyFailure, OutboundGroup?>> watchProxies();
  Stream<Either<ProxyFailure, List<OutboundGroup>>> watchActiveProxies();
  TaskEither<ProxyFailure, oldipinfo.IpInfo> getCurrentIpInfo(CancelToken cancelToken);
  TaskEither<ProxyFailure, Unit> selectProxy(String groupTag, String outboundTag);
  TaskEither<ProxyFailure, Unit> urlTest(String groupTag);
}

class ProxyRepositoryImpl with ExceptionHandler, InfraLogger implements ProxyRepository {
  ProxyRepositoryImpl({required this.singbox, required this.client});

  final HiddifyCoreService singbox;
  final DioHttpClient client;

  // @override
  // Stream<Either<ProxyFailure, List<OutboundGroup>>> watchProxies() {
  //   return singbox.watchGroups().map((event) {
  //     // final groupWithSelected = {
  //     //   for (final group in event) group.tag: group.selected,
  //     // };

  //     return event;
  //     // .map(
  //     //   (e) => ProxyGroupEntity(
  //     //     tag: e.tag,
  //     //     type: e.type,
  //     //     selected: e.selected,
  //     //     items: e.items
  //     //         .map(
  //     //           (e) => ProxyItemEntity(
  //     //             tag: e.tag,
  //     //             type: e.type,
  //     //             urlTestDelay: e.urlTestDelay,
  //     //             selectedTag: groupWithSelected[e.tag],
  //     //           ),
  //     //         )
  //     //         .filter((t) => t.isVisible)
  //     //         .toList(),
  //     //   ),
  //     // )
  //     // .toList();
  //   }).handleExceptions(
  //     (error, stackTrace) {
  //       loggy.error("error watching proxies", error, stackTrace);
  //       return ProxyUnexpectedFailure(error, stackTrace);
  //     },
  //   );
  // }

  @override
  Stream<Either<ProxyFailure, OutboundGroup?>> watchProxies() {
    return singbox.watchGroup().handleExceptions((error, stackTrace) {
      if (!HiddifyCoreService.isConnectionTerminated(error)) {
        loggy.error("error watching proxies", error, stackTrace);
      }
      return ProxyUnexpectedFailure(error, stackTrace);
    });
  }

  @override
  Stream<Either<ProxyFailure, List<OutboundGroup>>> watchActiveProxies() {
    return singbox.watchActiveGroups().handleExceptions((error, stackTrace) {
      if (!HiddifyCoreService.isConnectionTerminated(error)) {
        loggy.error("error watching active proxies", error, stackTrace);
      }
      return ProxyUnexpectedFailure(error, stackTrace);
    });
  }

  @override
  TaskEither<ProxyFailure, Unit> selectProxy(String groupTag, String outboundTag) {
    return exceptionHandler(
      () => singbox.selectOutbound(groupTag, outboundTag).mapLeft(ProxyUnexpectedFailure.new).run(),
      ProxyUnexpectedFailure.new,
    );
  }

  @override
  TaskEither<ProxyFailure, Unit> urlTest(String groupTag) {
    return exceptionHandler(
      () => singbox.urlTest(groupTag).mapLeft(ProxyUnexpectedFailure.new).run(),
      ProxyUnexpectedFailure.new,
    );
  }

  static final Map<String, oldipinfo.IpInfo Function(Map<String, dynamic> response)> _ipInfoSources = {
    // "https://geolocation-db.com/json/": IpInfo.fromGeolocationDbComJson, //bug response is not json
    "https://ipwho.is/": oldipinfo.IpInfo.fromIpwhoIsJson,
    "https://api.ip.sb/geoip/": oldipinfo.IpInfo.fromIpSbJson,
    "https://ipapi.co/json/": oldipinfo.IpInfo.fromIpApiCoJson,
    "https://ipinfo.io/json/": oldipinfo.IpInfo.fromIpInfoIoJson,
  };

  /// The source that answered last time. Trying it first keeps this to one
  /// request in the common case, instead of probing every endpoint on every
  /// refresh.
  static String? _lastWorkingSource;

  @override
  TaskEither<ProxyFailure, oldipinfo.IpInfo> getCurrentIpInfo(CancelToken cancelToken) {
    return TaskEither.tryCatch(() async {
      Object? error;
      final preferred = _lastWorkingSource;
      if (preferred != null) {
        for (final entry in _ipInfoSources.entries) {
          if (entry.key != preferred) continue;
          try {
            loggy.debug("getting current ip info using preferred [${entry.key}]");
            final response = await client.get<Map<String, dynamic>>(
              entry.key,
              cancelToken: cancelToken,
              proxyOnly: true,
            );
            if (response.statusCode == 200 && response.data != null) {
              return entry.value(response.data!);
            }
          } catch (e, s) {
            loggy.debug("preferred ip source [${entry.key}] failed", e, s);
            error = e;
            _lastWorkingSource = null;
          }
          break;
        }
      }
      // Every source is asked at once and the first answer wins. Probing them
      // one after another meant waiting out the full retry budget of each
      // endpoint before trying the next, which is minutes when the proxy port
      // is not up yet.
      final candidates = [
        for (final source in _ipInfoSources.entries)
          if (source.key != preferred) source,
      ];
      try {
        return await Future.any(
          candidates.map((source) async {
            loggy.debug("getting current ip info using [${source.key}]");
            final response = await client.get<Map<String, dynamic>>(
              source.key,
              cancelToken: cancelToken,
              proxyOnly: true,
            );
            if (response.statusCode != 200 || response.data == null) {
              throw UnableToRetrieveIp(null, StackTrace.current);
            }
            _lastWorkingSource = source.key;
            return source.value(response.data!);
          }),
        );
      } catch (e) {
        throw UnableToRetrieveIp(error ?? e, StackTrace.current);
      }
    }, ProxyUnexpectedFailure.new);
  }
}
