import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:grpc/grpc.dart';
import 'package:hiddify/core/model/directories.dart';
import 'package:hiddify/gen/hiddify_core_generated_bindings.dart';
import 'package:hiddify/hiddifycore/core_interface/core_interface.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:hiddify/hiddifycore/generated/v2/hello/hello.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hello/hello_service.pbgrpc.dart';
import 'package:hiddify/utils/custom_loggers.dart';

import 'package:path/path.dart' as p;

final _logger = infraLogger('HiddifyCoreFFI');
typedef StopFunc = Pointer<Utf8> Function();
typedef StopFuncDart = Pointer<Utf8> Function();

class CoreInterfaceDesktop extends CoreInterface with InfraLogger {
  static final HiddifyCoreNativeLibrary _box = _gen();

  static HiddifyCoreNativeLibrary _gen() {
    String fullPath = "";
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      fullPath = "hiddify-core";
    }
    if (Platform.isWindows) {
      fullPath = p.join(fullPath, "hiddify-core.dll");
    } else if (Platform.isMacOS) {
      fullPath = p.join(fullPath, "hiddify-core.dylib");
    } else {
      fullPath = p.join(fullPath, "hiddify-core.so");
    }

    _logger.debug('hiddify-core native libs path: "$fullPath"');
    final lib = DynamicLibrary.open(fullPath);
    // final stopFunc = lib.lookup<NativeFunction<StopFunc>>('stop').asFunction<StopFunc>();
    // final errPtr2 = stopFunc();
    // final err = errPtr2.cast<Utf8>().toDartString();

    return HiddifyCoreNativeLibrary(lib);
  }

  Future<bool> isMusl() async {
    try {
      // A hung `ldd` (a broken shim, a busy loader) used to block startup with no timeout at all.
      final result = await Process.run('ldd', ['--version']).timeout(const Duration(seconds: 3));
      return result.stdout.toString().toLowerCase().contains('musl');
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Set by [setup], see [CoreInterface.channelReplaced].
  bool _channelReplaced = true;

  @override
  bool get channelReplaced => _channelReplaced;

  final port = 17078;
  static String generateRandomPassword(int length) {
    const characters = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random();
    return List.generate(length, (_) => characters[random.nextInt(characters.length)]).join();
  }

  static final String secret = generateRandomPassword(100);

  ClientChannel? _channel;

  /// Whether the core answers on [channel].
  ///
  /// Bounded: a call to a core that is gone waits forever otherwise, and the
  /// whole setup - with everything awaiting it - waits along with it.
  Future<bool> _hello(ClientChannel channel) async {
    try {
      await HelloClient(channel).sayHello(
        HelloRequest(name: "test"),
        options: CallOptions(timeout: const Duration(seconds: 2)),
      );
      return true;
    } catch (e) {
      loggy.debug("hello failed: $e");
      return false;
    }
  }

  @override
  Future<String> setup(Directories directories, bool debug, int mode) async {
    // A resume, a reconnect and every connect run setup, and replacing the
    // channel each time moved the listeners the UI reads onto a new connection
    // in the middle of the connect: the status then came back as stopped while
    // the core was starting, and the button flipped to "tap to connect" and
    // back. A channel that still answers is kept.
    if (_channel case final existing?) {
      if (await _hello(existing)) {
        _channelReplaced = false;
        loggy.info("core channel still answering, keeping it");
        return "";
      }
      loggy.info("core channel is gone, setting up again");
    }
    _channelReplaced = true;
    const channelOption = ChannelCredentials.insecure();
    final helloChannel = ClientChannel(
      '127.0.0.1',
      port: port,
      options: const ChannelOptions(credentials: channelOption),
    );
    final helloClient = HelloClient(helloChannel);

    try {
      await helloClient.sayHello(HelloRequest(name: "test"), options: CallOptions(timeout: const Duration(seconds: 4)));
      loggy.info("core is already started!");
    } catch (e) {
      //core is not started yet

      final errPtr = _box.setup(
        directories.baseDir.path.toNativeUtf8().cast(),
        directories.workingDir.path.toNativeUtf8().cast(),
        directories.tempDir.path.toNativeUtf8().cast(),
        SetupMode.GRPC_NORMAL_INSECURE.value,
        "127.0.0.1:$port".toNativeUtf8().cast(),
        secret.toNativeUtf8().cast(),
        0,
        debug ? 1 : 0,
      );
      final err = errPtr.cast<Utf8>().toDartString();

      if (err.isNotEmpty) {
        return err;
      }
      final res = await helloClient.sayHello(
        HelloRequest(name: "test"),
        options: CallOptions(timeout: const Duration(seconds: 4)),
      );
      loggy.info(res.toString());
    } finally {
      unawaited(helloChannel.shutdown());
    }
    // setup runs again every time the app is resumed. The channel it replaces
    // used to stay open until its idle timeout, one more connection per resume.
    // shutdown is graceful: calls still running on it finish first.
    final previousChannel = _channel;
    _channel = ClientChannel(
      'localhost',
      port: port,
      options: const ChannelOptions(
        credentials: ChannelCredentials.insecure(),
        // credentials: ChannelCredentials.secure(
        //   password: secret,
        //   onBadCertificate: (certificate, host) => true,
        // ),
      ),
    );
    bgClient = fgClient = CoreClient(_channel!);
    unawaited(previousChannel?.shutdown());

    return "";
  }

  @override
  Future<bool> restart(String path, String name) async {
    return false;
  }

  @override
  Future<bool> stop() async {
    // There is no extra stop work on desktop: the core is stopped over gRPC
    // (bgClient.stop) and runs in-process. Returning false here made
    // HiddifyCoreService.stop log a bogus "core reported a failure while
    // stopping" on every shutdown.
    return true;
  }
}
