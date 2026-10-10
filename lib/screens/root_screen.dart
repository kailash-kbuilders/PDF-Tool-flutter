import 'package:flutter/material.dart';

import '../theme.dart';
import '../ui.dart';
import 'home_screen.dart';
import 'recent_screen.dart';
import 'settings_screen.dart';
import 'tools_screen.dart';

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  int _index = 0;

  static const _titles = ['PDF Toolkit', 'Tools', 'Recent', 'Settings'];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: buildAppBar(
        context,
        title: _index == 0
            ? Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(7),
                    child: Image.asset('assets/logo.png', width: 28, height: 28),
                  ),
                  const SizedBox(width: 10),
                  const Text('PDF Toolkit'),
                ],
              )
            : Text(_titles[_index]),
      ),
      body: IndexedStack(
        index: _index,
        children: [
          HomeScreen(onSeeAllRecent: () => setState(() => _index = 2)),
          const ToolsScreen(),
          const RecentScreen(),
          const SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        height: 62,
        selectedIndex: _index,
        backgroundColor: scheme.surface,
        indicatorColor: dark ? const Color(0xFF5A1519) : const Color(0xFFFFE0E1),
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home, color: AppColors.red),
              label: 'Home'),
          NavigationDestination(
              icon: Icon(Icons.grid_view_outlined),
              selectedIcon: Icon(Icons.grid_view, color: AppColors.red),
              label: 'Tools'),
          NavigationDestination(
              icon: Icon(Icons.history),
              selectedIcon: Icon(Icons.history, color: AppColors.red),
              label: 'Recent'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings, color: AppColors.red),
              label: 'Settings'),
        ],
      ),
    );
  }
}
