import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
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
final List<ValueNotifier<Map<String, dynamic>>> botWorldNotifiers = List.generate(5, (_) =>
  ValueNotifier<Map<String, dynamic>>({'joined': false, 'hasPosition': false, 'x': 0.0, 'y': 0.0, 'z': 0.0, 'yaw': 0.0, 'pitch': 0.0, 'loadedChunks': 0, 'chunkDataBytes': 0, 'blockUpdates': 0, 'lastChunkX': 0, 'lastChunkZ': 0}));
final List<ValueNotifier<Map<String, dynamic>>> botChunkNotifiers = List.generate(5, (_) => ValueNotifier<Map<String, dynamic>>({}));
final List<ValueNotifier<Map<String, dynamic>>> botInventoryNotifiers = List.generate(5, (_) => ValueNotifier<Map<String, dynamic>>({'slots': <dynamic>[], 'received': false}));

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
      } else if (call.method == 'botWorld' && mounted) {
        final data = Map<String, dynamic>.from(call.arguments as Map);
        final id = data['botId'] as int?;
        if (id != null && id >= 0 && id < botWorldNotifiers.length) botWorldNotifiers[id].value = data;
      } else if (call.method == 'botChunk' && mounted) {
        final data = Map<String, dynamic>.from(call.arguments as Map);
        final id = data['botId'] as int?;
        if (id != null && id >= 0 && id < botChunkNotifiers.length) {
          final key = '${data['chunkX']},${data['chunkZ']}';
          final chunks = Map<String, dynamic>.from(botChunkNotifiers[id].value);
          // Keep a bounded live window; each chunk now also carries sparse 3D sections.
          chunks.remove(key);
          chunks[key] = data;
          while (chunks.length > 64) {
            chunks.remove(chunks.keys.first);
          }
          botChunkNotifiers[id].value = chunks;
        }
      } else if (call.method == 'botInventory' && mounted) {
        final data = Map<String, dynamic>.from(call.arguments as Map);
        final id = data['botId'] as int?;
        if (id != null && id >= 0 && id < botInventoryNotifiers.length) {
          final old = Map<String, dynamic>.from(botInventoryNotifiers[id].value);
          final slots = List<dynamic>.from(old['slots'] as List? ?? <dynamic>[]);
          final incoming = List<dynamic>.from(data['slots'] as List? ?? <dynamic>[]);
          if (data['patch'] == true) {
            for (final raw in incoming) {
              final item = Map<String, dynamic>.from(raw as Map);
              final slot = item['slot'] as int? ?? -1;
              if (slot >= 0 && slot < 46) {
                while (slots.length <= slot) { slots.add({'slot': slots.length, 'id': -1, 'count': 0}); }
                slots[slot] = item;
              }
            }
          } else {
            slots
              ..clear()
              ..addAll(incoming);
          }
          botInventoryNotifiers[id].value = {'slots': slots, 'received': true};
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

  Future<void> sendBotCommand([String? rawCommand]) async {
    final command = (rawCommand ?? commandController.text).trim();
    if (command.isEmpty) return;
    try {
      await _botChannel.invokeMethod<bool>('sendCommand', {'botId': active, 'command': command});
      if (rawCommand == null) commandController.clear();
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
      actions: [
        IconButton(
          tooltip: 'Чат и команды',
          icon: const Icon(Icons.terminal, color: purple),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => WorldScreen(
              botName: current.nickname.text,
              botStatus: botMessages[active],
              events: botActivity[active],
              onSend: (command) => sendBotCommand(command),
            ),
          )),
        ),
        IconButton(
          tooltip: 'Живые данные мира Minecraft',
          icon: const Icon(Icons.videogame_asset, color: purple),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => LiveWorldScreen(botId: active),
          )),
        ),
      ],
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

// First version of the world screen. Live position/entity packets will populate
// the radar in a follow-up protocol update; this page already shows bot events
// and lets the user send commands without returning to the dashboard.
class WorldScreen extends StatefulWidget {
  const WorldScreen({
    super.key,
    required this.botName,
    required this.botStatus,
    required this.events,
    required this.onSend,
  });
  final String botName;
  final String botStatus;
  final List<String> events;
  final Future<void> Function(String) onSend;

  @override
  State<WorldScreen> createState() => _WorldScreenState();
}

class _WorldScreenState extends State<WorldScreen> {
  final command = TextEditingController();
  Timer? refreshTimer;
  @override
  void initState() {
    super.initState();
    // The bot event list is owned by the dashboard; refresh this page so
    // incoming server chat/status events remain visible while it is open.
    refreshTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    command.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final value = command.text.trim();
    if (value.isEmpty) return;
    await widget.onSend(value);
    command.clear();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      backgroundColor: deepPurple,
      title: const Text('ЧАТ И КОМАНДЫ', style: TextStyle(fontWeight: FontWeight.w800)),
    ),
    body: SafeArea(child: ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Card(color: panel, child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            const Icon(Icons.circle, color: Colors.greenAccent, size: 12),
            const SizedBox(width: 9),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.botName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
              const SizedBox(height: 4),
              Text(widget.botStatus, style: const TextStyle(color: Colors.white70)),
            ])),
          ]),
        )),
        const SizedBox(height: 12),
        Card(color: panel, child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('КОМАНДА В МИРЕ', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            TextField(
              controller: command,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => submit(),
              decoration: InputDecoration(
                hintText: '/lite, /hub, /home',
                prefixIcon: const Icon(Icons.terminal),
                suffixIcon: IconButton(icon: const Icon(Icons.send, color: purple), onPressed: submit),
                border: const OutlineInputBorder(),
              ),
            ),
          ]),
        )),
        const SizedBox(height: 12),
        Card(color: panel, child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('ЧАТ И СОБЫТИЯ', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Container(
              height: 260,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: deepPurple, borderRadius: BorderRadius.circular(10)),
              child: widget.events.isEmpty
                ? const Text('Ожидаю сообщения сервера…', style: TextStyle(color: Colors.white60))
                : ListView.builder(
                    reverse: true,
                    itemCount: widget.events.length,
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(widget.events[widget.events.length - 1 - index],
                        style: const TextStyle(fontSize: 12, height: 1.25)),
                    ),
                  ),
            ),
          ]),
        )),
      ],
    )),
  );
}


class LiveWorldScreen extends StatefulWidget {
  const LiveWorldScreen({super.key, required this.botId});
  final int botId;
  @override
  State<LiveWorldScreen> createState() => _LiveWorldScreenState();
}

class _LiveWorldScreenState extends State<LiveWorldScreen> {
  static const MethodChannel _channel = MethodChannel('masterme4a/bot_control');
  Timer? _holdTimer;
  double _startX = 0, _startY = 0, _baseYaw = 0, _basePitch = 0;
  bool _looking = false;
  String _message = 'Подключи бота и дождись позиции';

  Future<void> _step(double forward, double strafe, {bool jump = false, bool shift = false, bool sprint = false}) async {
    try {
      await _channel.invokeMethod<bool>('moveBot', {
        'botId': widget.botId, 'forward': forward, 'strafe': strafe,
        'jump': jump, 'shift': shift, 'sprint': sprint,
      });
      if (mounted) setState(() => _message = 'Команда движения отправлена');
    } on PlatformException catch (e) {
      if (mounted) setState(() => _message = e.message ?? 'Ошибка движения');
    }
  }

  void _hold(double forward, double strafe, {bool sprint = false, bool shift = false}) {
    _holdTimer?.cancel();
    _step(forward, strafe, sprint: sprint, shift: shift);
    _holdTimer = Timer.periodic(const Duration(milliseconds: 180), (_) => _step(forward, strafe, sprint: sprint, shift: shift));
  }

  void _release() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _step(0, 0);
  }

  void _showInventory() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => InventoryScreen(botId: widget.botId),
    ));
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      backgroundColor: deepPurple,
      title: const Text('BOT GAME VIEW • CONTROL'),
      actions: [
        IconButton(tooltip: 'Инвентарь бота', onPressed: _showInventory, icon: const Icon(Icons.inventory_2, color: purple)),
        IconButton(tooltip: 'Прыжок', onPressed: () => _step(0, 0, jump: true), icon: const Icon(Icons.arrow_upward, color: purple)),
      ],
    ),
    body: SafeArea(child: ValueListenableBuilder<Map<String, dynamic>>(
      valueListenable: botWorldNotifiers[widget.botId],
      builder: (context, w, _) {
        final connected = w['joined'] == true && w['hasPosition'] == true;
        final x = (w['x'] as num? ?? 0).toDouble();
        final y = (w['y'] as num? ?? 0).toDouble();
        final z = (w['z'] as num? ?? 0).toDouble();
        return Column(children: [
          Expanded(child: ValueListenableBuilder<Map<String, dynamic>>(
            valueListenable: botChunkNotifiers[widget.botId],
            builder: (context, chunks, __) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (e) {
                _looking = true;
                _startX = e.localPosition.dx; _startY = e.localPosition.dy;
                _baseYaw = (w['yaw'] as num? ?? 0).toDouble();
                _basePitch = (w['pitch'] as num? ?? 0).toDouble();
              },
              onPanUpdate: (e) {
                if (!_looking) return;
                final yaw = _baseYaw + (e.localPosition.dx - _startX) * 0.35;
                final pitch = (_basePitch - (e.localPosition.dy - _startY) * 0.25).clamp(-90.0, 90.0);
                _channel.invokeMethod<bool>('lookBot', {'botId': widget.botId, 'yaw': yaw, 'pitch': pitch}).catchError((_) {});
              },
              onPanEnd: (_) => _looking = false,
              child: Container(
                width: double.infinity, margin: const EdgeInsets.all(12),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(color: const Color(0xFF15111E), borderRadius: BorderRadius.circular(18), border: Border.all(color: purple.withOpacity(.55))),
                child: Stack(children: [
                  Positioned.fill(child: CustomPaint(painter: _LiveFirstPersonPainter(
                    chunks: chunks, playerX: x, playerY: y, playerZ: z,
                    yaw: (w['yaw'] as num? ?? 0).toDouble(),
                    pitch: (w['pitch'] as num? ?? 0).toDouble(),
                  ))),
                  const Center(child: IgnorePointer(child: Text('+', style: TextStyle(color: Colors.white, fontSize: 19, shadows: [Shadow(color: Colors.black, blurRadius: 5)])))),
                  Positioned(left: 12, top: 12, child: Text('BOT ${widget.botId + 1} • ${w['loadedChunks'] ?? 0} CHUNKS', style: const TextStyle(color: purple, fontSize: 11))),
                  Positioned(right: 12, top: 12, child: Text('FIRST PERSON', style: TextStyle(color: connected ? Colors.greenAccent : Colors.redAccent, fontWeight: FontWeight.bold))),
                  Positioned(left: 0, right: 0, bottom: 10, child: IgnorePointer(child: Center(child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(color: Colors.black.withOpacity(.42), borderRadius: BorderRadius.circular(8)),
                    child: const Text('LIVE WORLD • WASD / СМОТРИ ПЕРЕТАСКИВАНИЕМ', style: TextStyle(color: Colors.white70, fontSize: 9)),
                  )))),
                ]),
              ),
            ),
          )),

          Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), child: Column(children: [
            Text(_message, style: const TextStyle(color: Colors.white54, fontSize: 11)),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              _button(Icons.keyboard_arrow_up, 'Вперёд', 1, 0),
              _button(Icons.keyboard_arrow_down, 'Назад', -1, 0),
              _button(Icons.chevron_left, 'Влево', 0, -1),
              _button(Icons.chevron_right, 'Вправо', 0, 1),
              IconButton(tooltip: 'Прыжок', onPressed: () => _step(0, 0, jump: true), icon: const Icon(Icons.arrow_upward, color: purple, size: 28)),
            ]),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              OutlinedButton.icon(onPressed: () => _step(0, 0, shift: true), icon: const Icon(Icons.keyboard_arrow_down), label: const Text('Присесть')),
              const SizedBox(width: 10),
              OutlinedButton.icon(onPressed: () => _step(1, 0, sprint: true), icon: const Icon(Icons.directions_run), label: const Text('Бег')),
            ]),
            const Text('Управление ботом • перетащи экран, чтобы повернуть камеру', textAlign: TextAlign.center, style: TextStyle(color: Colors.white38, fontSize: 10)),
          ])),
        ]);
      },
    )),
  );

  Widget _button(IconData icon, String label, double forward, double strafe) => GestureDetector(
    onTap: () => _step(forward, strafe),
    onLongPressStart: (_) => _hold(forward, strafe),
    onLongPressEnd: (_) => _release(),
    child: Container(width: 52, height: 58, decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(12), border: Border.all(color: purple.withOpacity(.4))),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(icon, color: purple, size: 28), Text(label, style: const TextStyle(fontSize: 9, color: Colors.white70))])),
  );
}


/// Dedicated, responsive inventory page. Item sprites/names are not available from
/// the current native bridge, so slots show the server item ID and stack count.
class InventoryScreen extends StatelessWidget {
  const InventoryScreen({super.key, required this.botId});
  final int botId;

  Widget _sectionTitle(String title, String trailing) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 18, 2, 9),
    child: Row(children: [
      Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: .7))),
      Text(trailing, style: const TextStyle(color: Colors.white38, fontSize: 11)),
    ]),
  );

  Widget _slotGrid(BuildContext context, List<dynamic> slots, List<int> indexes, {int columns = 9}) {
    final valid = indexes.where((i) => i >= 0 && i < slots.length).toList();
    return LayoutBuilder(builder: (context, constraints) {
      const gap = 5.0;
      final cell = ((constraints.maxWidth - gap * (columns - 1)) / columns).clamp(28.0, 48.0).toDouble();
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: valid.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns, crossAxisSpacing: gap, mainAxisSpacing: gap,
          mainAxisExtent: cell,
        ),
        itemBuilder: (context, index) {
          final slot = valid[index];
          final item = Map<String, dynamic>.from(slots[slot] as Map);
          return InventorySlotTile(
            botId: botId,
            slot: slot,
            itemId: item['id'] as int? ?? -1,
            count: item['count'] as int? ?? 0,
          );
        },
      );
    });
  }

  Widget _itemCard(int slot, dynamic raw, {double width = 56}) {
    final item = Map<String, dynamic>.from(raw as Map);
    return SizedBox(width: width, child: InventorySlotTile(
      botId: botId,
      slot: slot,
      itemId: item['id'] as int? ?? -1,
      count: item['count'] as int? ?? 0,
    ));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      backgroundColor: deepPurple,
      title: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('ИНВЕНТАРЬ', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
        Text('BOT • ЖИВЫЕ ДАННЫЕ', style: TextStyle(color: purple, fontSize: 10, letterSpacing: 1)),
      ]),
    ),
    body: SafeArea(child: ValueListenableBuilder<Map<String, dynamic>>(
      valueListenable: botInventoryNotifiers[botId],
      builder: (context, inventory, _) {
        final slots = List<dynamic>.from(inventory['slots'] as List? ?? <dynamic>[]);
        if (inventory['received'] != true || slots.length < 46) {
          return Center(child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 76, height: 76, decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(24)),
                child: const Icon(Icons.inventory_2_outlined, color: purple, size: 38)),
              const SizedBox(height: 18),
              const Text('Инвентарь пока пуст', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('Подключи бота к серверу и подожди, пока сервер отправит содержимое инвентаря.',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.white60, height: 1.4)),
            ]),
          ));
        }
        return ListView(padding: const EdgeInsets.fromLTRB(14, 12, 14, 24), children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFF39215C), Color(0xFF241638)]),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: purple.withOpacity(.35)),
            ),
            child: Row(children: [
              const Icon(Icons.inventory_2, color: purple, size: 28),
              const SizedBox(width: 12),
              const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Инвентарь бота', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                SizedBox(height: 3),
                Text('Слоты обновляются при изменениях на сервере', style: TextStyle(color: Colors.white60, fontSize: 11)),
              ])),
              const Icon(Icons.circle, color: Colors.greenAccent, size: 9),
            ]),
          ),
          _sectionTitle('ЭКИПИРОВКА', '4 слота'),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            for (final slot in [5, 6, 7, 8]) _itemCard(slot, slots[slot], width: 56),
          ]),
          _sectionTitle('ОСНОВНОЙ ИНВЕНТАРЬ', '27 слотов'),
          _slotGrid(context, slots, List.generate(27, (i) => i + 9)),
          _sectionTitle('БЫСТРЫЙ ДОСТУП', '9 слотов'),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(14)),
            child: _slotGrid(context, slots, List.generate(9, (i) => i + 36)),
          ),
          _sectionTitle('ВТОРАЯ РУКА', '1 слот'),
          Align(alignment: Alignment.centerLeft, child: _itemCard(45, slots[45], width: 56)),
          _sectionTitle('КРАФТИНГ', '2 × 2'),
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Expanded(child: _slotGrid(context, slots, [1, 2, 3, 4], columns: 2)),
            const SizedBox(width: 12),
            const Icon(Icons.arrow_forward, color: purple),
            const SizedBox(width: 12),
            _itemCard(0, slots[0], width: 56),
          ]),
          const SizedBox(height: 18),
          const Text('Пока предметы показаны по ID протокола. Названия и игровые текстуры добавим отдельным обновлением.',
            style: TextStyle(color: Colors.white38, fontSize: 11, height: 1.4)),
        ]);
      },
    )),
  );
}

class InventorySlotTile extends StatelessWidget {
  const InventorySlotTile({super.key, required this.botId, required this.slot, required this.itemId, required this.count});
  final int botId;
  final int slot;
  final int itemId;
  final int count;

  Future<void> _showActions(BuildContext context) async {
    if (itemId < 0 || count <= 0) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (sheetContext) => SafeArea(child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 22),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 42, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(5))),
          const SizedBox(height: 16),
          Text('Предмет $itemId', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          Text('Слот $slot • Количество: $count', style: const TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: _actionButton(sheetContext, 'ЛКМ', Icons.mouse, 'left')),
            const SizedBox(width: 8),
            Expanded(child: _actionButton(sheetContext, 'ПКМ', Icons.ads_click, 'right')),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _actionButton(sheetContext, 'Выкинуть 1', Icons.remove_circle_outline, 'drop')),
            const SizedBox(width: 8),
            Expanded(child: _actionButton(sheetContext, 'Выкинуть всё', Icons.delete_outline, 'dropStack')),
          ]),
        ]),
      )),
    );
  }

  Widget _actionButton(BuildContext context, String label, IconData icon, String action) => FilledButton.tonal(
    onPressed: () async {
      Navigator.of(context).pop();
      try {
        await const MethodChannel('masterme4a/bot_control').invokeMethod<bool>('inventoryClick', {
          'botId': botId, 'slot': slot, 'action': action,
        });
      } on PlatformException catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message ?? 'Действие не выполнено')));
      } catch (_) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Не удалось отправить действие')));
      }
    },
    style: FilledButton.styleFrom(minimumSize: const Size(0, 48), backgroundColor: deepPurple),
    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(icon, size: 17), const SizedBox(width: 6),
      Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
    ]),
  );

  @override
  Widget build(BuildContext context) {
    final empty = itemId < 0 || count <= 0;
    return GestureDetector(
      onLongPress: empty ? null : () => _showActions(context),
      child: Container(
        decoration: BoxDecoration(
          color: empty ? const Color(0xFF171020) : const Color(0xFF34234A),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: empty ? Colors.white10 : purple.withOpacity(.48)),
          boxShadow: empty ? null : [BoxShadow(color: purple.withOpacity(.08), blurRadius: 5)],
        ),
        child: Stack(children: [
          Positioned(left: 4, top: 3, child: Text('$slot', style: const TextStyle(color: Colors.white30, fontSize: 8))),
          Center(child: Text(
            empty ? '—' : '$itemId',
            maxLines: 1, overflow: TextOverflow.fade,
            style: TextStyle(color: empty ? Colors.white24 : Colors.white, fontSize: 11, fontWeight: FontWeight.w800),
          )),
          if (!empty) Positioned(right: 4, bottom: 3, child: Text('$count',
            style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold))),
        ]),
      ),
    );
  }
}

/// Live first-person voxel raycaster. It renders the actual sparse 3D block-state
/// data received for this bot; colors are provisional until the 1.21.4 texture atlas
/// and block-model registry are bundled with the app.
class _LiveFirstPersonPainter extends CustomPainter {
  _LiveFirstPersonPainter({required this.chunks, required this.playerX, required this.playerY,
    required this.playerZ, required this.yaw, required this.pitch});
  final Map<String, dynamic> chunks;
  final double playerX, playerY, playerZ, yaw, pitch;

  Color _blockColor(int state, double shade) {
    final hue = ((state * 47 + 95) % 360).toDouble();
    final sat = 0.38 + (state % 5) * 0.045;
    final light = (0.42 + (state % 7) * 0.018) * shade;
    return HSLColor.fromAHSL(1, hue, sat, light.clamp(0.12, 0.78).toDouble()).toColor();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final sky = Paint()..shader = const LinearGradient(
      begin: Alignment.topCenter, end: Alignment.bottomCenter,
      colors: [Color(0xFF527FA8), Color(0xFFB5C9D8), Color(0xFF59606A)],
      stops: [0, .62, 1],
    ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, sky);
    if (chunks.isEmpty) {
      final p = TextPainter(text: const TextSpan(text: 'Ожидаю 3D-чанки от сервера…',
        style: TextStyle(color: Colors.white, fontSize: 13, shadows: [Shadow(color: Colors.black, blurRadius: 4)])),
        textDirection: TextDirection.ltr)..layout(maxWidth: size.width - 20);
      p.paint(canvas, Offset((size.width-p.width)/2, size.height*.72));
      return;
    }

    // Build sparse lookup only from chunks near the current player.
    final voxels = <String, Map<int, int>>{};
    final pcx = (playerX / 16).floor(), pcz = (playerZ / 16).floor();
    for (final entry in chunks.entries) {
      final c = entry.key.split(',');
      if (c.length != 2) continue;
      final cx = int.tryParse(c[0]), cz = int.tryParse(c[1]);
      if (cx == null || cz == null || (cx-pcx).abs()>3 || (cz-pcz).abs()>3) continue;
      final data = Map<String, dynamic>.from(entry.value as Map);
      final sections = data['sections'] as List?;
      if (sections == null) continue;
      for (final raw in sections) {
        final sec = Map<String, dynamic>.from(raw as Map);
        final sy = (sec['sectionY'] as num?)?.toInt() ?? 0;
        final indexes = sec['indices'] as List? ?? const [];
        final states = sec['states'] as List? ?? const [];
        final count = math.min(indexes.length, states.length);
        if (count == 0) continue;
        final vox = <int, int>{};
        for (var i=0; i<count; i++) {
          final id = (states[i] as num).toInt();
          if (id != 0) vox[(indexes[i] as num).toInt()] = id;
        }
        voxels['$cx,$cz,$sy'] = vox;
      }
    }

    const rw = 120, rh = 68;
    final pixelW = size.width / rw, pixelH = size.height / rh;
    final yawR = yaw * math.pi / 180, pitchR = pitch * math.pi / 180;
    final syaw = math.sin(yawR), cyaw = math.cos(yawR);
    final sp = math.sin(pitchR), cp = math.cos(pitchR);
    final forward = <double>[-syaw*cp, -sp, cyaw*cp];
    final right = <double>[cyaw, 0, syaw];
    final up = <double>[syaw*sp, cp, -cyaw*sp];
    final eyeX = playerX, eyeY = playerY + 1.62, eyeZ = playerZ;
    final fov = math.tan(70 * math.pi / 360);
    final rectPaint = Paint()..style = PaintingStyle.fill;

    for (var py=0; py<rh; py++) {
      final ny = (1 - 2*(py+.5)/rh) * fov * (rh/rw);
      for (var px=0; px<rw; px++) {
        final nx = (2*(px+.5)/rw - 1) * fov;
        var dx = forward[0] + right[0]*nx + up[0]*ny;
        var dy = forward[1] + right[1]*nx + up[1]*ny;
        var dz = forward[2] + right[2]*nx + up[2]*ny;
        final len = math.sqrt(dx*dx+dy*dy+dz*dz);
        dx/=len; dy/=len; dz/=len;
        Color color = Color.lerp(const Color(0xFF9CB9CF), const Color(0xFF384451), (py/rh).clamp(0.0,1.0).toDouble())!;
        var distance = .18;
        while (distance < 58) {
          final wx = (eyeX + dx*distance).floor();
          final wy = (eyeY + dy*distance).floor();
          final wz = (eyeZ + dz*distance).floor();
          final cx = (wx/16).floor(), cz = (wz/16).floor();
          final lx = wx-cx*16, lz = wz-cz*16;
          final sectionY = (wy/16).floor(), ly = wy-sectionY*16;
          final section = voxels['$cx,$cz,$sectionY'];
          final state = section?[(ly*256)+(lz*16)+lx];
          if (state != null) {
            final shade = (1.0 - distance/100) * (dy.abs() > .72 ? 1.12 : (dx.abs() > .72 ? .82 : 1.0));
            color = _blockColor(state, shade);
            break;
          }
          distance += .22;
        }
        rectPaint.color = color;
        canvas.drawRect(Rect.fromLTWH(px*pixelW, py*pixelH, pixelW+.35, pixelH+.35), rectPaint);
      }
    }
    // Simple Minecraft-style hotbar overlay.
    final barW = math.min(size.width*.58, 270.0).toDouble(), slot = barW/9;
    final barLeft = (size.width-barW)/2, barTop = size.height-34;
    final barPaint = Paint()..color = const Color(0xB91A1720);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(barLeft-4,barTop-4,barW+8,30),const Radius.circular(5)),barPaint);
    final border = Paint()..color = const Color(0xCCFFFFFF)..style=PaintingStyle.stroke..strokeWidth=1.2;
    for(var i=0;i<9;i++){
      canvas.drawRect(Rect.fromLTWH(barLeft+i*slot,barTop,slot,22),Paint()..color=Color.fromARGB(55,255,255,255));
      if(i==0) canvas.drawRect(Rect.fromLTWH(barLeft+i*slot-1,barTop-1,slot+2,24),border);
    }
  }

  @override
  bool shouldRepaint(covariant _LiveFirstPersonPainter old) =>
    old.chunks != chunks || old.playerX != playerX || old.playerY != playerY ||
    old.playerZ != playerZ || old.yaw != yaw || old.pitch != pitch;
}

/// Top-down live chunk visualization using actual block state IDs from the server.
/// Textures are not mapped yet; height and block distribution are live.
class _LiveChunkMapPainter extends CustomPainter {
  _LiveChunkMapPainter({required this.chunks, required this.playerX, required this.playerZ});
  final Map<String, dynamic> chunks;
  final double playerX;
  final double playerZ;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF171322));
    if (chunks.isEmpty || size.isEmpty) {
      final p = TextPainter(text: const TextSpan(text: 'Данные чанков появятся после входа', style: TextStyle(color: Colors.white54, fontSize: 13)), textDirection: TextDirection.ltr);
      p.layout(maxWidth: size.width - 20);
      p.paint(canvas, Offset((size.width - p.width) / 2, size.height / 2));
      return;
    }
    final scale = math.min(size.width, size.height) / 112.0;
    final center = Offset(size.width / 2, size.height / 2);
    final playerChunkX = (playerX / 16).floor();
    final playerChunkZ = (playerZ / 16).floor();
    final paint = Paint()..style = PaintingStyle.fill;
    for (final entry in chunks.entries) {
      final parts = entry.key.split(',');
      if (parts.length != 2) continue;
      final cx = int.tryParse(parts[0]); final cz = int.tryParse(parts[1]);
      if (cx == null || cz == null || (cx - playerChunkX).abs() > 4 || (cz - playerChunkZ).abs() > 4) continue;
      final data = Map<String, dynamic>.from(entry.value as Map);
      final states = (data['states'] as List?)?.cast<num>();
      final heights = (data['heights'] as List?)?.cast<num>();
      if (states == null || states.length < 256) continue;
      for (var z = 0; z < 16; z++) {
        for (var x = 0; x < 16; x++) {
          final idx = z * 16 + x;
          final state = states[idx].toInt();
          if (state == 0) continue;
          final worldX = cx * 16 + x;
          final worldZ = cz * 16 + z;
          final dx = worldX - playerX;
          final dz = worldZ - playerZ;
          final px = center.dx + dx * scale;
          final py = center.dy + dz * scale;
          final height = heights != null && heights.length > idx ? heights[idx].toInt() : 0;
          final hue = (state * 47 + 95) % 360;
          final saturation = 0.35 + (state % 4) * 0.08;
          final light = (0.35 + ((height + 64).clamp(0, 320) / 320) * 0.32).clamp(0.25, 0.72);
          paint.color = HSLColor.fromAHSL(1, hue.toDouble(), saturation, light).toColor();
          canvas.drawRect(Rect.fromLTWH(px, py, scale * 0.96, scale * 0.96), paint);
        }
      }
    }
    // Mark the bot's current location and facing direction.
    final marker = Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 2;
    canvas.drawCircle(center, scale * 1.2, marker);
    canvas.drawLine(center, center + const Offset(0, -1) * scale * 2.5, marker);
  }

  @override
  bool shouldRepaint(covariant _LiveChunkMapPainter old) => old.chunks != chunks || old.playerX != playerX || old.playerZ != playerZ;
}

/// First-person Minecraft-inspired voxel demo.
/// This local demo is not the connected server's live world yet.
class Demo3DScreen extends StatefulWidget {
  const Demo3DScreen({super.key});
  @override
  State<Demo3DScreen> createState() => _Demo3DScreenState();
}

class _Demo3DScreenState extends State<Demo3DScreen> {
  double yaw = 0;
  double pitch = 0.08;
  double zoom = 1.0;
  double cameraX = 0;
  double cameraZ = 9;
  Offset? dragOrigin;
  double startYaw = 0;
  double startPitch = 0;
  double startZoom = 1;

  void resetView() => setState(() {
    yaw = 0;
    pitch = 0.08;
    zoom = 1;
    cameraX = 0;
    cameraZ = 9;
  });

  void moveCamera(double forward, double strafe) => setState(() {
    cameraX += -math.sin(yaw) * forward + math.cos(yaw) * strafe;
    cameraZ += -math.cos(yaw) * forward - math.sin(yaw) * strafe;
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      backgroundColor: deepPurple,
      title: const Text('MINECRAFT • ПЕРВОЕ ЛИЦО', style: TextStyle(fontWeight: FontWeight.w800)),
      actions: [
        IconButton(
          tooltip: 'Сбросить вид',
          onPressed: resetView,
          icon: const Icon(Icons.restart_alt, color: purple),
        ),
      ],
    ),
    body: SafeArea(child: Column(children: [
      Expanded(child: Padding(
        padding: const EdgeInsets.all(12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF28154A), Color(0xFF10091B)],
              ),
            ),
            child: LayoutBuilder(builder: (context, constraints) {
              return GestureDetector(
                onScaleStart: (details) {
                  dragOrigin = details.focalPoint;
                  startYaw = yaw;
                  startPitch = pitch;
                  startZoom = zoom;
                },
                onScaleUpdate: (details) {
                  setState(() {
                    yaw = startYaw + (details.focalPoint.dx - (dragOrigin?.dx ?? details.focalPoint.dx)) * 0.009;
                    pitch = (startPitch - (details.focalPoint.dy - (dragOrigin?.dy ?? details.focalPoint.dy)) * 0.006)
                        .clamp(-0.12, 1.05).toDouble();
                    zoom = (startZoom * details.scale).clamp(0.55, 2.4).toDouble();
                  });
                },
                onScaleEnd: (_) => dragOrigin = null,
                child: CustomPaint(
                  size: Size(constraints.maxWidth, constraints.maxHeight),
                  painter: _VoxelDemoPainter(yaw: yaw, pitch: pitch, zoom: zoom, cameraX: cameraX, cameraZ: cameraZ),
                  child: Stack(children: [
                    const SizedBox.expand(),
                    Center(child: IgnorePointer(child: Text('+', style: TextStyle(
                      color: Colors.white.withOpacity(.8), fontSize: 24, fontWeight: FontWeight.w300,
                      shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                    )))),
                  ]),
                ),
              );
            }),
          ),
        ),
      )),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Card(
          color: panel,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Row(children: [
                Icon(Icons.view_in_ar, color: purple),
                SizedBox(width: 8),
                Text('ВИД ОТ ПЕРВОГО ЛИЦА', style: TextStyle(fontWeight: FontWeight.bold)),
                Spacer(),
                Text('MINECRAFT • DEMO', style: TextStyle(color: purple, fontSize: 11, fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 8),
              const Text('Потяни мышью или пальцем, чтобы осмотреться. Кнопки ниже перемещают камеру. Это демонстрационная карта, не живой мир сервера.',
                style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.35)),
              const SizedBox(height: 8),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                IconButton(
                  tooltip: 'Влево',
                  onPressed: () => moveCamera(0, -0.6),
                  icon: const Icon(Icons.chevron_left, color: purple, size: 30),
                ),
                IconButton(
                  tooltip: 'Вперёд',
                  onPressed: () => moveCamera(0.6, 0),
                  icon: const Icon(Icons.keyboard_arrow_up, color: purple, size: 30),
                ),
                IconButton(
                  tooltip: 'Назад',
                  onPressed: () => moveCamera(-0.6, 0),
                  icon: const Icon(Icons.keyboard_arrow_down, color: purple, size: 30),
                ),
                IconButton(
                  tooltip: 'Вправо',
                  onPressed: () => moveCamera(0, 0.6),
                  icon: const Icon(Icons.chevron_right, color: purple, size: 30),
                ),
                IconButton(onPressed: resetView, icon: const Icon(Icons.center_focus_strong, color: purple)),
              ]),
            ]),
          ),
        ),
      ),
    ])),
  );
}

class _VoxelDemoPainter extends CustomPainter {
  _VoxelDemoPainter({required this.yaw, required this.pitch, required this.zoom, required this.cameraX, required this.cameraZ});
  final double yaw;
  final double pitch;
  final double zoom;
  final double cameraX;
  final double cameraZ;

  @override
  void paint(Canvas canvas, Size size) {
    final sky = Paint()..shader = const LinearGradient(
      begin: Alignment.topCenter, end: Alignment.bottomCenter,
      colors: [Color(0xFF33205C), Color(0xFF130B21)],
    ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, sky);

    // Floating stars and distant horizon give the scene depth.
    final starPaint = Paint()..color = const Color(0xFFBDA3FF).withOpacity(.65);
    for (var i = 0; i < 42; i++) {
      final x = ((i * 73 + 19) % 997) / 997 * size.width;
      final y = ((i * 47 + 13) % 431) / 431 * size.height * .52;
      canvas.drawCircle(Offset(x, y), i % 5 == 0 ? 1.8 : 1, starPaint);
    }

    final center = Offset(size.width * .5, size.height * .57);
    final focal = size.shortestSide * 1.25 * zoom;
    final blocks = <_VoxelBlock>[];
    // Layered grass/dirt island, arranged like a compact Minecraft demo map.
    for (var x = -6; x <= 6; x++) {
      for (var z = -6; z <= 6; z++) {
        final edge = math.max(x.abs(), z.abs());
        if (edge == 6 && ((x * 3 + z * 5).abs() % 4 == 0)) continue;
        final height = ((x * 7 + z * 11 + x * z).abs() % 3);
        for (var y = -2; y <= height; y++) {
          final top = y == height;
          final color = top ? const Color(0xFF5DBB65) :
              (y == -2 ? const Color(0xFF6B4A35) : const Color(0xFF8A6043));
          blocks.add(_VoxelBlock(x.toDouble(), y.toDouble(), z.toDouble(), color));
        }
      }
    }
    // A small stylized tree and colorful demo blocks.
    for (var y = 0; y < 3; y++) {
      blocks.add(_VoxelBlock(-2, y.toDouble() + 1, 1, const Color(0xFF795238)));
    }
    for (var x = -4; x <= 0; x++) {
      for (var z = -1; z <= 3; z++) {
        for (var y = 3; y <= 5; y++) {
          if ((x + z + y).abs() % 4 != 0) {
            blocks.add(_VoxelBlock(x.toDouble(), y.toDouble(), z.toDouble(), const Color(0xFF329B55)));
          }
        }
      }
    }
    blocks.add(_VoxelBlock(3, 1, -2, const Color(0xFF9B5CFF)));
    blocks.add(_VoxelBlock(3, 2, -2, const Color(0xFFB98AFF)));
    blocks.add(_VoxelBlock(4, 1, -2, const Color(0xFF4EA5FF)));
    blocks.add(_VoxelBlock(4, 2, -2, const Color(0xFF83C6FF)));

    final projected = <_ProjectedVoxel>[];
    for (final block in blocks) {
      final points3 = <List<double>>[
        [block.x, block.y, block.z], [block.x + 1, block.y, block.z],
        [block.x + 1, block.y + 1, block.z], [block.x, block.y + 1, block.z],
        [block.x, block.y, block.z + 1], [block.x + 1, block.y, block.z + 1],
        [block.x + 1, block.y + 1, block.z + 1], [block.x, block.y + 1, block.z + 1],
      ];
      final points = points3.map((p) => _project(p[0], p[1], p[2], center, focal)).toList();
      final depth = points.fold<double>(0, (sum, p) => sum + p.depth) / points.length;
      if (depth <= 0.2) continue; // Do not draw blocks behind the first-person camera.
      projected.add(_ProjectedVoxel(points, block.color, depth));
    }
    projected.sort((a, b) => b.depth.compareTo(a.depth));

    final faces = <List<int>>[
      [0, 1, 2, 3], // front
      [1, 5, 6, 2], // right
      [4, 5, 6, 7], // back
      [0, 4, 7, 3], // left
      [3, 2, 6, 7], // top
      [0, 1, 5, 4], // bottom
    ];
    for (final voxel in projected) {
      for (var faceIndex = 0; faceIndex < faces.length; faceIndex++) {
        final face = faces[faceIndex];
        // Hide faces pointing away from the camera to keep the scene clean.
        final visible = faceIndex == 4 ||
            (faceIndex == 0 && math.sin(yaw) < .15) ||
            (faceIndex == 1 && math.cos(yaw) > -.15) ||
            (faceIndex == 2 && math.sin(yaw) > -.15) ||
            (faceIndex == 3 && math.cos(yaw) < .15);
        if (!visible) continue;
        final path = Path()..moveTo(voxel.points[face[0]].screen.dx, voxel.points[face[0]].screen.dy);
        for (var j = 1; j < face.length; j++) {
          path.lineTo(voxel.points[face[j]].screen.dx, voxel.points[face[j]].screen.dy);
        }
        path.close();
        final shade = faceIndex == 4 ? 1.12 : (faceIndex == 1 || faceIndex == 0 ? .82 : .65);
        final color = Color.fromARGB(
          voxel.color.alpha,
          (voxel.color.red * shade).round().clamp(0, 255).toInt(),
          (voxel.color.green * shade).round().clamp(0, 255).toInt(),
          (voxel.color.blue * shade).round().clamp(0, 255).toInt(),
        );
        canvas.drawPath(path, Paint()..color = color);
        canvas.drawPath(path, Paint()
          ..color = const Color(0xFF21152D).withOpacity(.32)
          ..style = PaintingStyle.stroke
          ..strokeWidth = .7);
      }
    }

    final title = TextPainter(
      text: const TextSpan(text: 'MASTERME4A • MINECRAFT POV DEMO', style: TextStyle(
        color: Colors.white70, fontSize: 11, letterSpacing: 1.2, fontWeight: FontWeight.bold,
      )),
      textDirection: TextDirection.ltr,
    )..layout();
    title.paint(canvas, const Offset(14, 14));
  }

  _ProjectedPoint _project(double x, double y, double z, Offset center, double focal) {
    // First-person camera: at eye height, looking toward -Z when yaw is zero.
    final dx = x - cameraX;
    final dy = y - 1.62;
    final dz = z - cameraZ;
    final cy = math.cos(yaw);
    final sy = math.sin(yaw);
    final cameraSide = dx * cy + dz * sy;
    final depth = -dx * sy - dz * cy;
    final cp = math.cos(pitch);
    final sp = math.sin(pitch);
    final cameraHeight = dy * cp + depth * sp;
    final safeDepth = math.max(depth, 0.08);
    final perspective = focal / safeDepth;
    return _ProjectedPoint(Offset(center.dx + cameraSide * perspective, center.dy - cameraHeight * perspective), depth);
  }

  @override
  bool shouldRepaint(covariant _VoxelDemoPainter oldDelegate) =>
      oldDelegate.yaw != yaw || oldDelegate.pitch != pitch || oldDelegate.zoom != zoom ||
      oldDelegate.cameraX != cameraX || oldDelegate.cameraZ != cameraZ;
}

class _VoxelBlock {
  const _VoxelBlock(this.x, this.y, this.z, this.color);
  final double x, y, z;
  final Color color;
}

class _ProjectedPoint {
  const _ProjectedPoint(this.screen, this.depth);
  final Offset screen;
  final double depth;
}

class _ProjectedVoxel {
  const _ProjectedVoxel(this.points, this.color, this.depth);
  final List<_ProjectedPoint> points;
  final Color color;
  final double depth;
}
