import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const Masterme4aApp());
const purple = Color(0xFF9B5CFF);
const deepPurple = Color(0xFF160D27);
const panel = Color(0xFF241638);
const minecraftProtocol = 769; // Java 1.21.4
const holyWorldLiteCommand = '/lite';
const holyWorldFirstMenuSlot = 3;
const holyWorldTrioLiteSlot = 25;

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
  static const MethodChannel _botChannel = MethodChannel('masterme4a/bot_control');
  final bots = List.generate(5, (i) => BotProfile(i + 1));
  final botMessages = List<String>.filled(5, 'Отключён');
  final botActivity = List.generate(5, (_) => <String>[]);
  final commandController = TextEditingController();
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
  void initState() {
    super.initState();
    _botChannel.setMethodCallHandler((call) async {
      if (call.method == 'botEvent' && mounted) {
        final data = Map<String, dynamic>.from(call.arguments as Map);
        final id = data['botId'] as int?;
        final message = data['message']?.toString() ?? 'Событие';
        if (id != null && id >= 0 && id < botActivity.length) {
          final now = DateTime.now();
          final time = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
          setState(() {
            botActivity[id].add('$time • $message');
            if (botActivity[id].length > 80) botActivity[id].removeRange(0, botActivity[id].length - 80);
          });
        }
      } else if (call.method == 'botStatus' && mounted) {
        final data = Map<String, dynamic>.from(call.arguments as Map);
        final id = data['botId'] as int?;
        final message = data['message']?.toString() ?? 'Нет данных';
        if (id != null && id >= 0 && id < botMessages.length) {
          setState(() => botMessages[id] = message);
        }
      }
    });
  }

  @override
  void dispose() {
    for (final bot in bots) { bot.nickname.dispose(); }
    host.dispose();
    port.dispose();
    commandController.dispose();
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

  Future<void> startConnection() async {
    if (mode == ConnectionMode.microsoft) {
      notice('Microsoft OAuth ещё не подключён. Не вводи пароль в приложение.');
      return;
    }
    final nickname = current.nickname.text.trim();
    final address = host.text.trim();
    final serverPort = int.tryParse(port.text.trim());
    if (nickname.isEmpty || address.isEmpty || serverPort == null || serverPort < 1 || serverPort > 65535) {
      notice('Проверь ник, адрес сервера и порт.');
      return;
    }
    setState(() => botMessages[active] = 'Запуск подключения…');
    try {
      await _botChannel.invokeMethod<bool>('connectBot', {
        'botId': active,
        'nickname': nickname,
        'host': address,
        'port': serverPort,
      });
      notice('Подключение профиля ' + (active + 1).toString() + ' запущено.');
    } on PlatformException catch (error) {
      setState(() => botMessages[active] = error.message ?? 'Ошибка подключения');
      notice(error.message ?? 'Не удалось запустить бота.');
    } catch (error) {
      setState(() => botMessages[active] = 'Ошибка: $error');
      notice('Ошибка запуска: $error');
    }
  }

  Future<void> sendBotCommand() async {
    final command = commandController.text.trim();
    if (command.isEmpty) return;
    try {
      await _botChannel.invokeMethod<bool>('sendCommand', {'botId': active, 'command': command});
      commandController.clear();
    } on PlatformException catch (error) {
      notice(error.message ?? 'Не удалось отправить команду');
    }
  }

  Future<void> disconnectCurrent() async {
    try {
      await _botChannel.invokeMethod<bool>('disconnectBot', {'botId': active});
      if (mounted) setState(() => botMessages[active] = 'Отключён');
    } catch (error) {
      notice('Не удалось отключить профиль: $error');
    }
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
          subtitle: Text('Сетевой модуль: MCProtocolLib · Java 1.21.4'),
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
            const SizedBox(height: 14),
            const Text('АВТОВЫБОР HOLYWORLD LITE', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: deepPurple,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: purple.withOpacity(.55)),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Команда чата: /lite'),
                  SizedBox(height: 6),
                  Text('Первое меню: слот 3'),
                  SizedBox(height: 6),
                  Text('Второе меню: слот 25'),
                  SizedBox(height: 6),
                  Text('Цель: ТриоЛайт №25', style: TextStyle(fontWeight: FontWeight.bold, color: purple)),
                  SizedBox(height: 10),
                  Text('После входа приложение отправляет /lite и выбирает 3-й, затем 25-й слот при получении меню. Вход по нику возможен только на серверах, разрешающих offline-mode.',
                    style: TextStyle(color: Colors.white70, height: 1.35)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(width: double.infinity, child: OutlinedButton.icon(
              onPressed: checking ? null : checkServer,
              icon: checking ? const SizedBox(width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.wifi_tethering),
              label: Text(checking ? 'Проверяем...' : 'Проверить сервер'))),
            const SizedBox(height: 8),
            SizedBox(width: double.infinity, child: FilledButton.icon(
              onPressed: startConnection, icon: const Icon(Icons.login),
              label: const Text('Подключить профиль'))),
            const SizedBox(height: 8),
            Text('Состояние BOT ${active + 1}: ${botMessages[active]}', style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 8),
            SizedBox(width: double.infinity, child: OutlinedButton.icon(
              onPressed: disconnectCurrent, icon: const Icon(Icons.link_off),
              label: const Text('Отключить профиль'))),
          ]),
        )),
        const SizedBox(height: 14),
        Card(color: panel, child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('КОМАНДЫ БОТА', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            TextField(
              controller: commandController,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => sendBotCommand(),
              decoration: InputDecoration(
                hintText: '/lite, /hub, /home',
                prefixIcon: const Icon(Icons.terminal),
                suffixIcon: IconButton(icon: const Icon(Icons.send, color: purple), onPressed: sendBotCommand),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 6),
            const Text('Команда отправляется активному профилю. Можно вводить со слэшем.',
              style: TextStyle(color: Colors.white70, fontSize: 12)),
          ]),
        )),
        const SizedBox(height: 14),
        Card(color: panel, child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('СОБЫТИЯ БОТА', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Container(
              height: 180, width: double.infinity, padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: deepPurple, borderRadius: BorderRadius.circular(10)),
              child: botActivity[active].isEmpty
                ? const Text('Здесь появятся сообщения сервера и действия бота.', style: TextStyle(color: Colors.white60))
                : ListView.builder(
                    itemCount: botActivity[active].length,
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Text(botActivity[active][index], style: const TextStyle(fontSize: 12)),
                    ),
                  ),
            ),
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
            'Игровое подключение реализовано через MCProtocolLib для Java 1.21.4. Режим по нику работает только если сервер разрешает offline-mode; он не обходит online-mode и не подменяет Microsoft-авторизацию. Если сервер требует лицензионный вход, бот будет отклонён. Microsoft OAuth пока не реализован.',
            style: TextStyle(color: Colors.white70, height: 1.4)),
        )),
      ]),
    ))),
  );
}
