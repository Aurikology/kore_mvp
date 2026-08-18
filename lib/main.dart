import 'package:flutter/material.dart';

import 'app/home_page.dart';
import 'services/history_store.dart';
import 'theme.dart';

void main() {
  // No async font fetch, no plugin initialization: fonts are bundled assets,
  // so startup is deterministic and works with the network off.
  //
  // The history store is constructed here and nowhere else. Widget tests pump
  // `KoreApp()` with no store and therefore touch no disk.
  runApp(KoreApp(store: HistoryStore.defaultLocation()));
}

class KoreApp extends StatelessWidget {
  /// Null keeps reset history in memory for the run. See `main`.
  final HistoryStore? store;

  const KoreApp({super.key, this.store});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KORE',
      theme: KoreTheme.darkTheme(),
      home: HomePage(store: store),
      debugShowCheckedModeBanner: false,
    );
  }
}
