import 'package:flutter/material.dart';

void main() => runApp(const InspectorExampleApp());

class InspectorExampleApp extends StatelessWidget {
  const InspectorExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Flutter Inspector Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6558D3)),
        scaffoldBackgroundColor: const Color(0xFFF5F5FA),
        useMaterial3: true,
      ),
      home: const InspectorExamplePage(),
    );
  }
}

class InspectorExamplePage extends StatelessWidget {
  const InspectorExamplePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'Flutter Element Tree',
              style: Theme.of(
                context,
              ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              '点击原生导航栏右侧的「Tree」查看这个页面的 Widget 和布局层级。',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 24),
            const _SummaryCard(),
            const SizedBox(height: 16),
            const _FeatureTile(
              icon: Icons.account_tree_outlined,
              title: 'Hierarchy',
              subtitle: 'Widget、Element 与 RenderObject 层级',
            ),
            const _FeatureTile(
              icon: Icons.straighten_outlined,
              title: 'Layout',
              subtitle: '节点 frame、offset 和 size',
            ),
            const _FeatureTile(
              icon: Icons.image_outlined,
              title: 'Screenshot',
              subtitle: '按 Element 获取对应区域截图',
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF6558D3), Color(0xFF8C7CF0)],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.flutter_dash, color: Colors.white, size: 36),
          SizedBox(height: 16),
          Text(
            'KKFlutterInspectorKit',
            style: TextStyle(
              color: Colors.white,
              fontSize: 21,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: 6),
          Text(
            'This card intentionally contains nested Flutter widgets.',
            style: TextStyle(color: Colors.white70, fontSize: 15),
          ),
        ],
      ),
    );
  }
}

class _FeatureTile extends StatelessWidget {
  const _FeatureTile({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Icon(icon),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}
