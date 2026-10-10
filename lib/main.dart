import 'package:flutter/material.dart';

import 'screens/root_screen.dart';
import 'store.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = AppStore();
  await store.load();
  runApp(PdfApp(store: store));
}

class PdfApp extends StatelessWidget {
  final AppStore store;
  const PdfApp({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return StoreScope(
      store: store,
      child: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          return MaterialApp(
            title: 'PDF Toolkit',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: store.dark ? ThemeMode.dark : ThemeMode.light,
            home: const RootScreen(),
          );
        },
      ),
    );
  }
}
