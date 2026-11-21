import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';

void main() => runApp(const Masterme4aApp());
const purple = Color(0xFF9B5CFF);
const deepPurple = Color(0xFF160D27);
const panel = Color(0xFF241638);
const minecraftProtocol = 769; // Java 1.21.4

enum ConnectionMode { microsoft, nickname }

class Masterme4aApp extends StatelessWidget {
  const Masterme4aApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'MASTERME4A Bot Control',
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: deepPurple,
      colorScheme: ColorScheme.fromSeed(seedColor: purple, brightness: Brightness.dark),
      useMaterial3: true,
    ),
    home: const Dashboard(),
  );
}

class BotProfile {
  BotProfile(this.number) : nickname = TextEditingController(text: 'Bot $number');
  final int number;
  final TextEditingController nickname;
  bool tapMouse = false;
  bool rightHold = false;
}

class _VarIntResult {
  const _VarIntResult(this.value, this.next);
  final int value;
  final int next;
}

List<int> _varInt(int value) {
  final out = <int>[];
  var v = value;
  do {
    var part = v & 0x7f;
    v >>>= 7;
    if (v != 0) part |= 0x80;
    out.add(part);
  } while (v != 0);
  return out;
}

_VarIntResult? _readVarInt(List<int> bytes, int start) {
  var result = 0;
  var shift = 0;
  var offset = start;
  while (true) {
    if (offset >= bytes.length) return null;
    final part = bytes[offset++];
    result |= (part & 0x7f) << shift;
    if ((part & 0x80) == 0) return _VarIntResult(result, offset);
    shift += 7;
    if (shift >= 35) throw const FormatException('Invalid VarInt');
  }
}

List<int> _packet(List<int> payload) => <int>[..._varInt(payload.length), ...payload];
List<int> _protocolString(String value) {
  final bytes = utf8.encode(value);
  return <int>[..._varInt(bytes.length), ...bytes];
}

/// Real Minecraft Java Status handshake for protocol 769 (1.21.4).
/// It checks server status only; it does not authenticate or join a world.
Future<Map<String, dynamic>> pingMinecraftServer(String host, int port) async {
  final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 8));
  final response = Completer<Map<String, dynamic>>();
  final received = <int>[];
  late StreamSubscription<List<int>> subscription;
  subscription = socket.listen(
    (chunk) {
      received.addAll(chunk);
      try {
        final frame = _readVarInt(received, 0);
        if (frame == null || received.length < frame.next + frame.value) return;
        final packetBytes = received.sublist(frame.next, frame.next + frame.value);
        final packetId = _readVarInt(packetBytes, 0);
        if (packetId == null || packetId.value != 0) {
          throw const FormatException('Unexpected status packet');
        }
        final stringLength = _readVarInt(packetBytes, packetId.next);
        if (stringLength == null) return;
        final start = stringLength.next;
        final end = start + stringLength.value;
        if (packetBytes.length < end) return;
        final decoded = jsonDecode(utf8.decode(packetBytes.sublist(start, end)));
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Invalid server status JSON');
        }
        if (!response.isCompleted) response.complete(decoded);
      } catch (error, stack) {
        if (!response.isCompleted) response.completeError(error, stack);
      }
    },
    onError: (Object error, StackTrace stack) {
      if (!response.isCompleted) response.completeError(error, stack);
    },
    onDone: () {
      if (!response.isCompleted) {
        response.completeError(const SocketException('Server closed before status response'));
      }
    },
    cancelOnError: true,
  );
  try {
    final handshake = <int>[
      0x00,
      ..._varInt(minecraftProtocol),
      ..._protocolString(host),
      (port >> 8) & 0xff,
      port & 0xff,
      0x01, // next state: status
    ];
    socket.add(_packet(handshake));
    socket.add(_packet(<int>[0x00])); // Status Request
    await socket.flush();
    return await response.future.timeout(const Duration(seconds: 8));
  } finally {
    await subscription.cancel();
    socket.destroy();
  }
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key});
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  final bots = List.generate(5, (i) => BotProfile(i + 1));
  final host = TextEditingController(text: 'lite.holyworld.me');
  final port = TextEditingController(text: '25565');
  int active = 0;
  ConnectionMode mode = ConnectionMode.nickname;
  bool checking = false;
  String serverStatus = 'Сервер ещё не проверен';
  String? serverVersion;
  int? onlinePlayers;
  int? maxPlayers;
  BotProfile get current => bots[active];

  @override
  void dispose() {
    for (final bot in bots) { bot.nickname.dispose(); }
    host.dispose();
    port.dispose();
    super.dispose();
  }

  void notice(String message) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
  );

  Future<void> checkServer() async {
    final address = host.text.trim();
    final p = int.tryParse(port.text.trim());
    if (address.isEmpty || p == null || p < 1 || p > 65535) {
      notice('Проверь адрес сервера и порт.');
      return;
    }
    setState(() {
      checking = true;
      serverStatus = 'Подключаемся...';
      serverVersion = null;
      onlinePlayers = null;
      maxPlayers = null;
    });
    try {
      final result = await pingMinecraftServer(address, p);
      final version = result['version'];
      final players = result['players'];
      final description = result['description'];
      String motd = '';
      if (description is String) {
        motd = description;
      } else if (description is Map<String, dynamic>) {
        motd = description['text']?.toString() ?? '';
      }
      if (!mounted) return;
      setState(() {
        serverStatus = motd.isEmpty ? 'Сервер ответил на Minecraft Status Ping' : motd;
        serverVersion = version is Map ? version['name']?.toString() : null;
        onlinePlayers = players is Map ? players['online'] as int? : null;
        maxPlayers = players is Map ? players['max'] as int? : null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() { serverStatus = 'Не удалось получить ответ: $error'; });
    } finally {
      if (mounted) setState(() => checking = false);
    }
  }

  void startConnection() {
    if (mode == ConnectionMode.microsoft) {
      notice('Microsoft OAuth ещё не реализован. Не вводи пароль в приложение.');
      return;
    }
    notice('Status Ping готов. Вход в игровой мир — следующий этап.');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      backgroundColor: deepPurple,
      title: const Row(children: [
        Icon(Icons.bolt, color: purple),
        SizedBox(width: 8),
        Text('MASTERME4A', style: TextStyle(fontWeight: FontWeight.w900)),
        SizedBox(width: 7),
        Text('BOT CONTROL', style: TextStyle(color: purple, fontSize: 12)),
      ]),
    ),
    body: SafeArea(child: Center(child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 900),
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Card(color: panel, child: const ListTile(
          leading: Icon(Icons.dns, color: purple, size: 32),
          title: Text('Minecraft Java 1.21.4', style: TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text('Сетевой модуль: Status Ping'),
          trailing: Chip(label: Text('ЭТАП 1')),
        )),
        const SizedBox(height: 18),
        const Text('ПРОФИЛИ БОТОВ', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, children: List.generate(5, (i) => ChoiceChip(
          label: Text('BOT \${i + 1}'),
          selected: active == i,
          selectedColor: purple.withOpacity(.3),
          onSelected: (_) => setState(() => active = i),
        ))),
        const SizedBox(height: 12),
        Card(color: panel, child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('ПРОФИЛЬ \${active + 1}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            TextField(controller: current.nickname, decoration: const InputDecoration(
              labelText: 'Игровой ник', prefixIcon: Icon(Icons.person_outline), border: OutlineInputBorder())),
            const SizedBox(height: 18),
            const Text('ТИП ПОДКЛЮЧЕНИЯ', style: TextStyle(fontWeight: FontWeight.bold)),
            RadioListTile<ConnectionMode>(
              contentPadding: EdgeInsets.zero, value: ConnectionMode.microsoft, groupValue: mode,
              onChanged: (v) => setState(() => mode = v!),
              title: const Text('С лицензией'), subtitle: const Text('Официальная авторизация Microsoft')),
            RadioListTile<ConnectionMode>(
              contentPadding: EdgeInsets.zero, value: ConnectionMode.nickname, groupValue: mode,
              onChanged: (v) => setState(() => mode = v!),
              title: const Text('По нику (offline-mode)'),
              subtitle: const Text('Только серверы, разрешающие offline-mode')),
            const SizedBox(height: 8),
            TextField(controller: host, decoration: const InputDecoration(
              labelText: 'Адрес сервера', prefixIcon: Icon(Icons.computer), border: OutlineInputBorder())),
            const SizedBox(height: 10),
            TextField(controller: port, keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Порт', border: OutlineInputBorder())),
            const SizedBox(height: 12),
            SizedBox(width: double.infinity, child: OutlinedButton.icon(
              onPressed: checking ? null : checkServer,
              icon: checking ? const SizedBox(width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.wifi_tethering),
              label: Text(checking ? 'Проверяем...' : 'Проверить сервер'))),
            const SizedBox(height: 8),
            SizedBox(width: double.infinity, child: FilledButton.icon(
              onPressed: startConnection, icon: const Icon(Icons.login),
              label: const Text('Войти профилем (следующий этап)'))),
          ]),
        )),
        const SizedBox(height: 14),
        Card(color: panel, child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('СТАТУС СЕРВЕРА', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(serverStatus),
            if (serverVersion != null) ...[
              const SizedBox(height: 6), Text('Версия: $serverVersion')],
            if (onlinePlayers != null && maxPlayers != null) ...[
              const SizedBox(height: 6), Text('Игроки: $onlinePlayers / $maxPlayers')],
          ]),
        )),
        const SizedBox(height: 18),
        const Text('ЛОКАЛЬНЫЕ ПЕРЕКЛЮЧАТЕЛИ',
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
        Card(color: panel, child: Column(children: [
          SwitchListTile(title: const Text('Tap Mouse'),
            subtitle: const Text('Игровое действие будет добавлено позже'),
            value: current.tapMouse, onChanged: (v) => setState(() => current.tapMouse = v)),
          SwitchListTile(title: const Text('Right Mouse Hold'),
            subtitle: const Text('Игровое действие будет добавлено позже'),
            value: current.rightHold, onChanged: (v) => setState(() => current.rightHold = v)),
        ])),
        const SizedBox(height: 12),
        const Card(color: panel, child: Padding(
          padding: EdgeInsets.all(14),
          child: Text(
            'Этап 1 реализует реальный Minecraft Java Status Ping: TCP-соединение, Handshake и запрос статуса. Он проверяет доступность сервера, но не входит в игровой мир. Следующий этап — Login Start и обработка пакетов входа на сервере, который разрешает offline-mode.',
            style: TextStyle(color: Colors.white70, height: 1.4)),
        )),
      ]),
    ))),
  );
}
