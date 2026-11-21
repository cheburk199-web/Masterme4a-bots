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
          tooltip: 'Экран мира',
          icon: const Icon(Icons.public, color: purple),
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
          tooltip: '3D демонстрация',
          icon: const Icon(Icons.view_in_ar, color: purple),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => const Demo3DScreen(),
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
  double radarYaw = 0;
  double radarZoom = 1.0;
  Offset? lastDragPoint;

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
      title: const Text('ЭКРАН МИРА', style: TextStyle(fontWeight: FontWeight.w800)),
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
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('РАДАР / ВИД СВЕРХУ', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1)),
            const SizedBox(height: 10),
            AspectRatio(
              aspectRatio: 1.05,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: GestureDetector(
                    onPanStart: (details) => lastDragPoint = details.localPosition,
                    onPanUpdate: (details) {
                      final previous = lastDragPoint ?? details.localPosition;
                      final delta = details.localPosition - previous;
                      lastDragPoint = details.localPosition;
                      setState(() {
                        radarYaw += delta.dx * 0.012;
                        radarYaw = ((radarYaw + math.pi) % (math.pi * 2)) - math.pi;
                        radarZoom = (radarZoom + delta.dy * 0.003).clamp(0.6, 1.8).toDouble();
                      });
                    },
                    onPanEnd: (_) => lastDragPoint = null,
                    child: CustomPaint(
                      painter: _WorldRadarPainter(yaw: radarYaw, zoom: radarZoom),
                      child: const Center(child: Text('BOT', style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12,
                      ))),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              const Text('ПОВОРОТ', style: TextStyle(color: Colors.white70, fontSize: 11)),
              Expanded(child: Slider(
                value: radarYaw,
                min: -math.pi,
                max: math.pi,
                onChanged: (value) => setState(() => radarYaw = value),
              )),
              IconButton(
                tooltip: 'Сбросить обзор',
                onPressed: () => setState(() { radarYaw = 0; radarZoom = 1; }),
                icon: const Icon(Icons.center_focus_strong, color: purple),
              ),
            ]),
            const Text('Зажми и веди мышью или пальцем по радару: горизонтально — вращение, вертикально — масштаб. Бот пока остаётся в центре.',
              style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.35)),
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

class _WorldRadarPainter extends CustomPainter {
  _WorldRadarPainter({required this.yaw, required this.zoom});
  final double yaw;
  final double zoom;

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()..color = const Color(0xFF10091B);
    canvas.drawRect(Offset.zero & size, background);

    final grid = Paint()
      ..color = const Color(0xFF51376D)
      ..strokeWidth = 1;
    const cell = 28.0;
    for (double x = 0; x <= size.width; x += cell) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (double y = 0; y <= size.height; y += cell) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final center = Offset(size.width / 2, size.height / 2);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(yaw);
    canvas.scale(zoom);
    canvas.translate(-center.dx, -center.dy);
    final rings = Paint()
      ..color = const Color(0xFF9B5CFF).withOpacity(.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (double radius = 35; radius < size.width * .48; radius += 35) {
      canvas.drawCircle(center, radius, rings);
    }
    final cross = Paint()
      ..color = const Color(0xFF9B5CFF)
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(center.dx, 0), Offset(center.dx, size.height), cross);
    canvas.drawLine(Offset(0, center.dy), Offset(size.width, center.dy), cross);

    final direction = Paint()..color = const Color(0xFF9B5CFF).withOpacity(.22);
    final cone = Path()
      ..moveTo(center.dx, center.dy)
      ..lineTo(center.dx - 42, center.dy - 70)
      ..lineTo(center.dx + 42, center.dy - 70)
      ..close();
    canvas.drawPath(cone, direction);
    canvas.restore();

    final marker = Paint()..color = const Color(0xFFB98AFF);
    final bot = Path()
      ..moveTo(center.dx, center.dy - 13)
      ..lineTo(center.dx - 11, center.dy + 10)
      ..lineTo(center.dx + 11, center.dy + 10)
      ..close();
    canvas.drawPath(bot, marker);
    canvas.drawCircle(center, 15, Paint()
      ..color = const Color(0xFFB98AFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
    final label = TextPainter(
      text: const TextSpan(text: 'N', style: TextStyle(
        color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold,
      )),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(canvas, Offset(size.width - label.width - 8, 8));
  }

  @override
  bool shouldRepaint(covariant _WorldRadarPainter oldDelegate) => oldDelegate.yaw != yaw || oldDelegate.zoom != zoom;
}


/// Lightweight Minecraft-inspired 3D voxel demo rendered in Flutter.
/// It is a visual demo scene, not a live 3D game client/world stream.
class Demo3DScreen extends StatefulWidget {
  const Demo3DScreen({super.key});
  @override
  State<Demo3DScreen> createState() => _Demo3DScreenState();
}

class _Demo3DScreenState extends State<Demo3DScreen> {
  double yaw = -0.65;
  double pitch = 0.42;
  double zoom = 1.0;
  Offset? dragOrigin;
  double startYaw = 0;
  double startPitch = 0;
  double startZoom = 1;

  void resetView() => setState(() {
    yaw = -0.65;
    pitch = 0.42;
    zoom = 1;
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      backgroundColor: deepPurple,
      title: const Text('3D ДЕМОНСТРАЦИЯ', style: TextStyle(fontWeight: FontWeight.w800)),
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
                  painter: _VoxelDemoPainter(yaw: yaw, pitch: pitch, zoom: zoom),
                  child: const SizedBox.expand(),
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
                Text('ВОКСЕЛЬНЫЙ МИР', style: TextStyle(fontWeight: FontWeight.bold)),
                Spacer(),
                Text('3D • DEMO', style: TextStyle(color: purple, fontSize: 11, fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 8),
              const Text('Перетаскивай пальцем или мышью, чтобы вращать сцену. Используй два пальца для приближения и отдаления.',
                style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.35)),
              const SizedBox(height: 8),
              Row(children: [
                const Icon(Icons.rotate_left, size: 17, color: Colors.white60),
                Expanded(child: Slider(
                  value: yaw % (math.pi * 2),
                  min: 0,
                  max: math.pi * 2,
                  onChanged: (v) => setState(() => yaw = v),
                )),
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
  _VoxelDemoPainter({required this.yaw, required this.pitch, required this.zoom});
  final double yaw;
  final double pitch;
  final double zoom;

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
      text: const TextSpan(text: 'MASTERME4A • 3D WORLD', style: TextStyle(
        color: Colors.white70, fontSize: 11, letterSpacing: 1.2, fontWeight: FontWeight.bold,
      )),
      textDirection: TextDirection.ltr,
    )..layout();
    title.paint(canvas, const Offset(14, 14));
  }

  _ProjectedPoint _project(double x, double y, double z, Offset center, double focal) {
    final dx = x - 0.5;
    final dz = z - 0.5;
    final rx = dx * math.cos(yaw) - dz * math.sin(yaw);
    final rz = dx * math.sin(yaw) + dz * math.cos(yaw);
    final ry = y - 0.5;
    final cy = math.cos(pitch);
    final sy = math.sin(pitch);
    final vy = ry * cy - rz * sy;
    final vz = ry * sy + rz * cy + 19;
    final perspective = focal / vz;
    return _ProjectedPoint(Offset(center.dx + rx * perspective, center.dy - vy * perspective), vz);
  }

  @override
  bool shouldRepaint(covariant _VoxelDemoPainter oldDelegate) =>
      oldDelegate.yaw != yaw || oldDelegate.pitch != pitch || oldDelegate.zoom != zoom;
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
