import 'package:flutter/material.dart';

import 'app/home_page.dart';
import 'theme.dart';

void main() {
  // No async font fetch, no plugin initialization: fonts are bundled assets,
  // so startup is deterministic and works with the network off.
  runApp(const KoreApp());
}

class KoreApp extends StatelessWidget {
  const KoreApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KORE',
      theme: KoreTheme.darkTheme(),
      home: const HomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}
