import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ui/home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const RoomScopeApp());
}

class RoomScopeApp extends StatelessWidget {
  const RoomScopeApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'RoomScope',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xff0c1117),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff67e8ba),
        brightness: Brightness.dark,
        surface: const Color(0xff141d25),
      ),
      appBarTheme: const AppBarTheme(backgroundColor: Color(0xff0c1117)),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    ),
    home: const HomeScreen(),
  );
}
