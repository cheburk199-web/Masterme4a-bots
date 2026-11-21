import 'package:flutter/material.dart';

void main() => runApp(const Masterme4aApp());

const purple = Color(0xFF9B5CFF);
const deepPurple = Color(0xFF160D27);
const panel = Color(0xFF241638);

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
  BotProfile(this.number)
      : nickname = TextEditingController(text: 'Bot $number');
  final int number;
  final TextEditingController nickname;
  bool tapMouse = false;
  bool rightHold = false;
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key});
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  final bots = List.generate(5, (i) => BotProfile(i + 1));
  final host = TextEditingController(text: '127.0.0.1');
  final port = TextEditingController(text: '25565');
  int active = 0;
  ConnectionMode mode = ConnectionMode.microsoft;
  BotProfile get current => bots[active];

  @override
  void dispose() {
    for (final bot in bots) {
      bot.nickname.dispose();
    }
    host.dispose();
    port.dispose();
    super.dispose();
  }

  void notice(String message) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
  );

  void startConnection() {
    if (mode == ConnectionMode.microsoft) {
      notice('Официальная Microsoft-авторизация ещё не подключена. Пароль Microsoft здесь не вводи.');
      return;
    }
    final address = host.text.trim();
    final p = int.tryParse(port.text.trim());
    if (current.nickname.text.trim().isEmpty) {
      notice('Укажи игровой ник.');
      return;
    }
    if (address.isEmpty || p == null || p < 1 || p > 65535) {
      notice('Проверь адрес сервера и порт.');
      return;
    }
    notice('Параметры сохранены. Minecraft-протокол ещё не подключён; реального входа пока нет.');
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
          subtitle: Text('Пять независимых профилей'),
          trailing: Chip(label: Text('ПРОТОТИП')),
        )),
        const SizedBox(height: 18),
        const Text('ПРОФИЛИ БОТОВ', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, children: List.generate(5, (i) => ChoiceChip(
          label: Text('BOT ${i + 1}'),
          selected: active == i,
          selectedColor: purple.withOpacity(.3),
          onSelected: (_) => setState(() => active = i),
        ))),
        const SizedBox(height: 12),
        Card(color: panel, child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('ПРОФИЛЬ ${active + 1}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            TextField(controller: current.nickname, decoration: const InputDecoration(
              labelText: 'Игровой ник', prefixIcon: Icon(Icons.person_outline),
              border: OutlineInputBorder())),
            const SizedBox(height: 18),
            const Text('ТИП ПОДКЛЮЧЕНИЯ', style: TextStyle(fontWeight: FontWeight.bold)),
            RadioListTile<ConnectionMode>(
              contentPadding: EdgeInsets.zero,
              value: ConnectionMode.microsoft,
              groupValue: mode,
              onChanged: (v) => setState(() => mode = v!),
              title: const Text('С лицензией'),
              subtitle: const Text('Официальный вход через Microsoft / Minecraft'),
            ),
            RadioListTile<ConnectionMode>(
              contentPadding: EdgeInsets.zero,
              value: ConnectionMode.nickname,
              groupValue: mode,
              onChanged: (v) => setState(() => mode = v!),
              title: const Text('По нику (offline-mode)'),
              subtitle: const Text('Только свой сервер или локальный сервер без online-auth'),
            ),
            if (mode == ConnectionMode.nickname) ...[
              const SizedBox(height: 8),
              TextField(controller: host, decoration: const InputDecoration(
                labelText: 'Адрес своего сервера', hintText: '127.0.0.1',
                prefixIcon: Icon(Icons.computer), border: OutlineInputBorder())),
              const SizedBox(height: 10),
              TextField(controller: port, keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Порт', border: OutlineInputBorder())),
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text('Этот режим не обходит авторизацию серверов вроде HolyWorld.',
                  style: TextStyle(color: Colors.orangeAccent)),
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(width: double.infinity, child: FilledButton.icon(
              onPressed: startConnection,
              icon: const Icon(Icons.link),
              label: const Text('Подключить профиль'),
            )),
          ]),
        )),
        const SizedBox(height: 18),
        const Text('ЛОКАЛЬНЫЕ ПЕРЕКЛЮЧАТЕЛИ', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
        Card(color: panel, child: Column(children: [
          SwitchListTile(
            title: const Text('Tap Mouse'),
            subtitle: const Text('Настройка профиля; игровое действие пока не подключено'),
            value: current.tapMouse,
            onChanged: (v) => setState(() => current.tapMouse = v)),
          SwitchListTile(
            title: const Text('Right Mouse Hold'),
            subtitle: const Text('Настройка профиля; игровое действие пока не подключено'),
            value: current.rightHold,
            onChanged: (v) => setState(() => current.rightHold = v)),
        ])),
        const SizedBox(height: 16),
        const Card(color: panel, child: Padding(
          padding: EdgeInsets.all(14),
          child: Text(
            'Сейчас добавлен выбор режима и поля профиля. Это ещё не полноценный Minecraft-сетевой движок: протокол 1.21.4 и авторизация не реализованы, поэтому приложение не утверждает, что бот подключён. Для лицензированного режима будет использоваться только официальный вход Microsoft; пароли приложение запрашивать не должно.',
            style: TextStyle(color: Colors.white70, height: 1.4),
          ),
        )),
      ]),
    ))),
  );
}
