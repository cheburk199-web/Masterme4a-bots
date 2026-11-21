import 'package:flutter/material.dart';

void main() => runApp(const Masterme4aApp());

const purple = Color(0xFF9B5CFF);
const deepPurple = Color(0xFF160D27);
const panel = Color(0xFF241638);

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

class Dashboard extends StatefulWidget {
  const Dashboard({super.key});
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  final bots = List.generate(5, (i) => BotProfile(i + 1));
  int active = 0;
  BotProfile get current => bots[active];

  @override
  void dispose() {
    for (final bot in bots) { bot.nickname.dispose(); }
    super.dispose();
  }

  void notice(String message) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), behavior: SnackBarBehavior.floating));

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
          title: Text('HolyWorld', style: TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text('Minecraft Java 1.21.4 · профиль подключения'),
          trailing: Chip(label: Text('OFFLINE')),
        )),
        const SizedBox(height: 18),
        const Text('ПРОФИЛИ БОТОВ', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, children: List.generate(5, (i) => ChoiceChip(
          label: Text('BOT ${i + 1}'), selected: active == i,
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
              labelText: 'Название / ник профиля', prefixIcon: Icon(Icons.person_outline),
              border: OutlineInputBorder())),
            SwitchListTile(
              contentPadding: EdgeInsets.zero, title: const Text('Tap Mouse'),
              subtitle: const Text('Макет переключателя — действие пока не подключено'),
              value: current.tapMouse, onChanged: (v) => setState(() => current.tapMouse = v)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero, title: const Text('Right Mouse Hold'),
              subtitle: const Text('Макет переключателя — действие пока не подключено'),
              value: current.rightHold, onChanged: (v) => setState(() => current.rightHold = v)),
            SizedBox(width: double.infinity, child: FilledButton.icon(
              onPressed: () => notice('Сетевой движок ещё не подключён.'),
              icon: const Icon(Icons.link), label: const Text('Подключить профиль'))),
          ]),
        )),
        const SizedBox(height: 18),
        const Text('ПАНЕЛЬ УПРАВЛЕНИЯ', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: MediaQuery.of(context).size.width > 600 ? 4 : 2,
          shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 2.2,
          children: const [
            _ActionTile(icon: Icons.arrow_upward, label: 'Вперёд'),
            _ActionTile(icon: Icons.arrow_downward, label: 'Назад'),
            _ActionTile(icon: Icons.inventory_2_outlined, label: 'Инвентарь'),
            _ActionTile(icon: Icons.stop_circle_outlined, label: 'Стоп'),
          ]),
        const SizedBox(height: 16),
        const Card(color: panel, child: Padding(
          padding: EdgeInsets.all(14),
          child: Text('Это UI-прототип: профили и переключатели работают локально. Подключение ботов и игровые команды пока не реализованы. Используй автоматизацию только на серверах, где она разрешена.',
            style: TextStyle(color: Colors.white70, height: 1.4)))),
      ]),
    ))),
  );
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.icon, required this.label});
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) => Card(color: panel, child: InkWell(
    borderRadius: BorderRadius.circular(16),
    onTap: () => ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Игровое управление ещё не подключено.'))),
    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(icon, color: purple), const SizedBox(width: 8), Text(label),
    ]),
  ));
}
