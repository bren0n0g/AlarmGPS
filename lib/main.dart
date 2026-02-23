import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:alarm/alarm.dart';
import 'package:geolocator/geolocator.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// --- GERENCIAMENTO DE TEMA E CONFIGURAÇÕES ---
class AppThemeState {
  final Color color;
  final bool isDark;
  AppThemeState(this.color, this.isDark);
}
final ValueNotifier<AppThemeState> themeNotifier = ValueNotifier(AppThemeState(Colors.deepPurple, true));

class AppSettings {
  static bool useGeofencing = true;
  static bool showWelcome = true;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    bool isDark = prefs.getBool('isDarkMode') ?? true;
    Color color = Color(prefs.getInt('themeColor') ?? Colors.deepPurple.value);
    useGeofencing = prefs.getBool('useGeofencing') ?? true;
    showWelcome = prefs.getBool('showWelcome') ?? true;
    themeNotifier.value = AppThemeState(color, isDark);
  }

  static Future<void> saveTheme(Color color, bool isDark) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isDarkMode', isDark);
    await prefs.setInt('themeColor', color.value);
    themeNotifier.value = AppThemeState(color, isDark);
  }

  static Future<void> saveConfigs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('useGeofencing', useGeofencing);
  }
}

// --- TAREFAS EM SEGUNDO PLANO ---
@pragma('vm:entry-point')
void checkGeofence(int id, Map<String, dynamic> data) async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppSettings.load();
  if (!AppSettings.useGeofencing) return;

  try {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) return;

    Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    final rotina = Rotina.fromJson(data);
    
    final distance = const Distance().as(LengthUnit.Meter, LatLng(position.latitude, position.longitude), rotina.origem);
    
    if (distance > 200) {
      await Alarm.stop(rotina.id.hashCode + 100); 
    }
  } catch (e) {
    debugPrint("Geofence erro: $e");
  }
}

@pragma('vm:entry-point')
void checkTrafficAndSetAlarm(int id, Map<String, dynamic> data) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Alarm.init();

  try {
    final rotina = Rotina.fromJson(data);
    final url = Uri.parse('https://api.tomtom.com/routing/1/calculateRoute/${rotina.origem.latitude},${rotina.origem.longitude}:${rotina.destino.latitude},${rotina.destino.longitude}/json?key=${rotina.tomTomKey}&departAt=now&traffic=true');
    final response = await http.get(url);

    if (response.statusCode == 200) {
      final json = jsonDecode(response.body);
      final travelTimeMinutes = (json['routes'][0]['summary']['travelTimeInSeconds'] / 60).round();

      final prefs = await SharedPreferences.getInstance();
      final routinesJson = prefs.getStringList('routines') ?? [];
      List<Rotina> rotinas = routinesJson.map((s) => Rotina.fromJson(jsonDecode(s))).toList();
      final index = rotinas.indexWhere((r) => r.id == rotina.id);
      if (index != -1) {
          rotinas[index].tempoPercursoAtualizado = travelTimeMinutes;
          await prefs.setStringList('routines', rotinas.map((r) => jsonEncode(r.toJson())).toList());
      }

      // Se o tempo for exatamente igual, não fazemos nada. 
      // Se for maior ou MENOR, ele prossegue e ajusta o alarme.
      if (travelTimeMinutes == rotina.tempoPercursoBase) return; 

      final agora = DateTime.now();
      final dataChegada = DateTime(agora.year, agora.month, agora.day, rotina.horaChegada.hour, rotina.horaChegada.minute);
      final horaDeAcordar = dataChegada.subtract(Duration(minutes: travelTimeMinutes + rotina.tempoPraSair));
      final horaDeSair = dataChegada.subtract(Duration(minutes: travelTimeMinutes));

      final alarmAcordarSettings = AlarmSettings(
        id: rotina.id.hashCode, dateTime: horaDeAcordar, assetAudioPath: 'assets/alarm.mp3', loopAudio: true, vibrate: true,
        volumeSettings: VolumeSettings.fade(volume: 1.0, fadeDuration: const Duration(seconds: 3)),
        notificationSettings: const NotificationSettings(title: 'Smart WakeUp', body: 'Hora de Acordar!', stopButton: 'Desligar'),
        warningNotificationOnKill: true, androidFullScreenIntent: true,
      );
      await Alarm.set(alarmSettings: alarmAcordarSettings);

      if (rotina.tempoPraSair > 0) {
        final alarmSairSettings = AlarmSettings(
          id: rotina.id.hashCode + 100, dateTime: horaDeSair, assetAudioPath: 'assets/alarm.mp3', loopAudio: true, vibrate: true,
          volumeSettings: VolumeSettings.fade(volume: 0.8, fadeDuration: const Duration(seconds: 3)),
          notificationSettings: const NotificationSettings(title: 'Smart WakeUp', body: 'Hora de Sair de Casa!', stopButton: 'Desligar'),
          warningNotificationOnKill: true, androidFullScreenIntent: true,
        );
        await Alarm.set(alarmSettings: alarmSairSettings);

        await AppSettings.load();
        if (AppSettings.useGeofencing) {
          DateTime timeToCheck = horaDeSair.subtract(const Duration(minutes: 2));
          if (timeToCheck.isAfter(DateTime.now())) {
            AndroidAlarmManager.oneShotAt(timeToCheck, rotina.id.hashCode + 200, checkGeofence, exact: true, wakeup: true, rescheduleOnReboot: true, params: rotina.toJson());
          }
        }
      }
    }
  } catch (e) {
    debugPrint("Erro fatal background: $e");
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AndroidAlarmManager.initialize();
  await Alarm.init();
  await AppSettings.load();
  runApp(const SmartWakeUpRoot());
}

class SmartWakeUpRoot extends StatelessWidget {
  const SmartWakeUpRoot({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppThemeState>(
      valueListenable: themeNotifier,
      builder: (context, themeState, _) {
        return MaterialApp(
          navigatorKey: navigatorKey,
          themeMode: themeState.isDark ? ThemeMode.dark : ThemeMode.light,
          theme: ThemeData(colorSchemeSeed: themeState.color, brightness: Brightness.light, useMaterial3: true),
          darkTheme: ThemeData(
            colorSchemeSeed: themeState.color, brightness: Brightness.dark, useMaterial3: true,
            scaffoldBackgroundColor: Colors.black, 
            appBarTheme: const AppBarTheme(backgroundColor: Colors.black, surfaceTintColor: Colors.transparent),
            bottomNavigationBarTheme: const BottomNavigationBarThemeData(backgroundColor: Colors.black),
            cardColor: const Color(0xFF121212), dialogBackgroundColor: const Color(0xFF121212),
          ),
          home: AppSettings.showWelcome ? const WelcomeScreen() : const MainScreen(),
        );
      },
    );
  }
}

// --- TELA DE BOAS VINDAS (ONBOARDING) ---
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});
  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  bool _dontShowAgain = false;

  void _finish() async {
    if (_dontShowAgain) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('showWelcome', false);
    }
    if (mounted) {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => const MainScreen()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.primary,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: (idx) => setState(() => _currentPage = idx),
                children: [
                  _buildPage(Icons.access_time_filled, "Smart WakeUp", "Seu novo despertador inteligente.\n\nEle monitora o trânsito em tempo real e te acorda mais cedo apenas se houver engarrafamento."),
                  _buildPage(Icons.map, "Como Usar", "Na aba 'Rotina', defina sua Origem, Destino e Hora de Chegada.\n\nClique no 'Marcador' para gerenciar e salvar seus locais favoritos!"),
                  _buildPage(Icons.gps_fixed, "Desarme Automático", "Se você sair de casa antes da hora, o app percebe pelo seu GPS e desarma o alarme de 'Saída' sozinho para não te incomodar."),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(3, (index) => Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: _currentPage == index ? 12 : 8,
                height: 8,
                decoration: BoxDecoration(color: _currentPage == index ? Colors.white : Colors.white54, borderRadius: BorderRadius.circular(4)),
              )),
            ),
            const SizedBox(height: 20),
            CheckboxListTile(
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text("Não mostrar esta apresentação novamente", style: TextStyle(color: Colors.white, fontSize: 13)),
              value: _dontShowAgain,
              checkColor: Theme.of(context).colorScheme.primary,
              activeColor: Colors.white,
              side: const BorderSide(color: Colors.white),
              onChanged: (val) => setState(() => _dontShowAgain = val ?? false),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: _finish,
                    child: const Text("PULAR", style: TextStyle(color: Colors.white70)),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      if (_currentPage < 2) {
                        _pageController.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeIn);
                      } else {
                        _finish();
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Theme.of(context).colorScheme.primary,
                    ),
                    child: Text(_currentPage < 2 ? "PRÓXIMA" : "COMEÇAR"),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPage(IconData icon, String title, String desc) {
    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 120, color: Colors.white),
          const SizedBox(height: 40),
          Text(title, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(height: 20),
          Text(desc, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, color: Colors.white, height: 1.5)),
        ],
      ),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;
  final List<Widget> _widgetOptions = <Widget>[
    const ConfiguracaoRotinaTab(),
    const GerenciadorAlarmesTab(),
    const SettingsTab(),
  ];

  @override
  void initState() {
    super.initState();
    Alarm.ringStream.stream.listen((AlarmSettings alarmSettings) {
      navigatorKey.currentState?.push(MaterialPageRoute(builder: (context) => RingScreen(alarmSettings: alarmSettings)));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(child: _widgetOptions.elementAt(_selectedIndex)),
      bottomNavigationBar: BottomNavigationBar(
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(icon: Icon(Icons.schedule), label: 'Rotina'),
          BottomNavigationBarItem(icon: Icon(Icons.alarm), label: 'Alarmes'),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: 'Ajustes'),
        ],
        currentIndex: _selectedIndex,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: Theme.of(context).colorScheme.primary,
        unselectedItemColor: Colors.grey,
        onTap: (index) => setState(() => _selectedIndex = index),
      ),
    );
  }
}

// --- ABA DE CONFIGURAÇÕES ---
class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

  final List<Color> _colors = const [
    Colors.deepPurple, Colors.blue, Colors.red, Colors.green,
    Colors.orange, Colors.teal, Colors.pink, Colors.cyan,
    Colors.amber, Colors.indigo, Colors.brown, Colors.lime,
    Colors.lightBlue, Colors.deepOrange, Colors.purple, Colors.blueGrey
  ];

  void _requestLocation(BuildContext context) async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Permissão negada.'), backgroundColor: Colors.red));
        AppSettings.useGeofencing = false;
        AppSettings.saveConfigs();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppThemeState>(
      valueListenable: themeNotifier,
      builder: (context, themeState, _) {
        return Scaffold(
          appBar: AppBar(title: const Text("Configurações", style: TextStyle(fontSize: 16))),
          body: ListView(
            padding: const EdgeInsets.all(16.0),
            children: [
              SwitchListTile(
                title: const Text("Modo Escuro (OLED)"),
                secondary: Icon(themeState.isDark ? Icons.dark_mode : Icons.light_mode),
                value: themeState.isDark,
                onChanged: (val) => AppSettings.saveTheme(themeState.color, val),
              ),
              const Divider(),
              SwitchListTile(
                title: const Text("Desarme Inteligente (Geofencing GPS)"),
                subtitle: const Text("Se você sair de casa mais cedo, o alarme de 'Saída' não tocará."),
                secondary: const Icon(Icons.gps_fixed),
                value: AppSettings.useGeofencing,
                onChanged: (val) {
                  AppSettings.useGeofencing = val;
                  AppSettings.saveConfigs();
                  if (val) _requestLocation(context);
                },
              ),
              const Divider(),
              const SizedBox(height: 10),
              const Text("Cor do Aplicativo", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 15),
              Wrap(
                spacing: 12, runSpacing: 12, alignment: WrapAlignment.center,
                children: _colors.map((color) {
                  bool isSelected = color.value == themeState.color.value;
                  return GestureDetector(
                    onTap: () => AppSettings.saveTheme(color, themeState.isDark),
                    child: CircleAvatar(
                      backgroundColor: color, radius: 24,
                      child: isSelected ? const Icon(Icons.check, color: Colors.white) : null,
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        );
      }
    );
  }
}

class RingScreen extends StatelessWidget {
  final AlarmSettings alarmSettings;
  const RingScreen({super.key, required this.alarmSettings});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.primary,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.alarm_on, size: 100, color: Colors.white),
              const SizedBox(height: 20),
              Text(alarmSettings.notificationSettings.title, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white), textAlign: TextAlign.center),
              const SizedBox(height: 10),
              Text(alarmSettings.notificationSettings.body, style: const TextStyle(fontSize: 18, color: Colors.white70), textAlign: TextAlign.center),
              const SizedBox(height: 60),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white, foregroundColor: Theme.of(context).colorScheme.primary,
                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                ),
                onPressed: () async { await Alarm.stop(alarmSettings.id); if (context.mounted) Navigator.pop(context); },
                child: const Text("DESLIGAR ALARME", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class Rotina {
  final String id;
  final String? nome;
  final LatLng origem;
  final LatLng destino;
  final String originAddress;
  final String destAddress;
  final TimeOfDay horaChegada;
  final List<bool> diasSemana;
  final int tempoPraSair;
  final int tempoPercursoBase;
  int? tempoPercursoAtualizado;
  bool isActive;
  final String tomTomKey;

  Rotina({
    required this.id, this.nome, required this.origem, required this.destino, required this.originAddress, required this.destAddress,
    required this.horaChegada, required this.diasSemana, required this.tempoPraSair, required this.tempoPercursoBase,
    this.tempoPercursoAtualizado, required this.tomTomKey, this.isActive = true,
  });

  Map<String, dynamic> toJson() => {
    'id': id, 'nome': nome, 'origemLat': origem.latitude, 'origemLng': origem.longitude, 'originAddress': originAddress, 'destAddress': destAddress,
    'horaChegadaHour': horaChegada.hour, 'horaChegadaMinute': horaChegada.minute, 'diasSemana': diasSemana, 'tempoPraSair': tempoPraSair,
    'tempoPercursoBase': tempoPercursoBase, 'tempoPercursoAtualizado': tempoPercursoAtualizado, 'isActive': isActive, 'tomTomKey': tomTomKey,
  };

  factory Rotina.fromJson(Map<String, dynamic> json) {
    return Rotina(
      id: json['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
      nome: json['nome'],
      origem: LatLng(json['origemLat'] ?? 0.0, json['origemLng'] ?? 0.0), destino: LatLng(json['destinoLat'] ?? 0.0, json['destinoLng'] ?? 0.0),
      originAddress: json['originAddress'] ?? '', destAddress: json['destAddress'] ?? '',
      horaChegada: TimeOfDay(hour: json['horaChegadaHour'] ?? 8, minute: json['horaChegadaMinute'] ?? 0),
      diasSemana: json['diasSemana'] != null ? List<bool>.from(json['diasSemana']) : List.filled(7, false),
      tempoPraSair: json['tempoPraSair'] ?? json['tempoPreparo'] ?? 40, tempoPercursoBase: json['tempoPercursoBase'] ?? 30, tempoPercursoAtualizado: json['tempoPercursoAtualizado'],
      isActive: json['isActive'] ?? true, tomTomKey: json['tomTomKey'] ?? '',
    );
  }
}

class GerenciadorAlarmesTab extends StatefulWidget { const GerenciadorAlarmesTab({super.key}); @override GerenciadorAlarmesTabState createState() => GerenciadorAlarmesTabState(); }
class GerenciadorAlarmesTabState extends State<GerenciadorAlarmesTab> {
  List<Rotina> _rotinas = [];
  @override void initState() { super.initState(); _loadRoutines(); }

  Future<void> _loadRoutines() async {
    final prefs = await SharedPreferences.getInstance();
    final routinesJson = prefs.getStringList('routines') ?? [];
    bool needsSave = false;
    List<Rotina> loaded = routinesJson.map((jsonString) { try { return Rotina.fromJson(jsonDecode(jsonString)); } catch (e) { return null; } }).where((r) => r != null).cast<Rotina>().toList();

    final alarmesNativos = await Alarm.getAlarms();
    final activeAlarmIds = alarmesNativos.map((a) => a.id).toSet();
    for (var rotina in loaded) {
      bool isOneOff = !rotina.diasSemana.contains(true);
      if (isOneOff && rotina.isActive) {
        if (!activeAlarmIds.contains(rotina.id.hashCode)) { rotina.isActive = false; needsSave = true; }
      }
    }
    setState(() => _rotinas = loaded);
    if (needsSave) await _saveRoutines();
  }

  Future<void> _saveRoutines() async { final prefs = await SharedPreferences.getInstance(); await prefs.setStringList('routines', _rotinas.map((r) => jsonEncode(r.toJson())).toList()); }

  Future<void> _toggleRoutine(int index, bool isActive) async {
    setState(() => _rotinas[index].isActive = isActive);
    await _saveRoutines();
    if (!isActive) {
      await Alarm.stop(_rotinas[index].id.hashCode); await Alarm.stop(_rotinas[index].id.hashCode + 100);
      for (int i = 0; i < 8; i++) await AndroidAlarmManager.cancel(_rotinas[index].id.hashCode + i);
      await AndroidAlarmManager.cancel(_rotinas[index].id.hashCode + 200);
    } else { _agendarTodasAsRotinas(_rotinas); }
  }

  Future<void> _deleteRoutine(int index) async {
    final rotina = _rotinas[index];
    await Alarm.stop(rotina.id.hashCode); await Alarm.stop(rotina.id.hashCode + 100);
    for (int i = 0; i < 8; i++) await AndroidAlarmManager.cancel(rotina.id.hashCode + i);
    await AndroidAlarmManager.cancel(rotina.id.hashCode + 200);
    setState(() => _rotinas.removeAt(index)); await _saveRoutines();
  }

  void _editRoutine(Rotina rotina) {
    Navigator.push(context, MaterialPageRoute(builder: (context) => ConfiguracaoRotinaTab(rotinaExistente: rotina))).then((value) { if (value != null && value) _loadRoutines(); });
  }

  void _agendarTodasAsRotinas(List<Rotina> rotinas) {
    final now = DateTime.now();
    for (final rotina in rotinas) {
      for (int i = 0; i < 8; i++) AndroidAlarmManager.cancel(rotina.id.hashCode + i);
      if (rotina.isActive) {
        bool isOneOff = !rotina.diasSemana.contains(true);
        if (isOneOff) {
          DateTime targetChegada = DateTime(now.year, now.month, now.day, rotina.horaChegada.hour, rotina.horaChegada.minute);
          DateTime horaAcordarBase = targetChegada.subtract(Duration(minutes: rotina.tempoPercursoBase + rotina.tempoPraSair));
          if (horaAcordarBase.isBefore(now)) horaAcordarBase = horaAcordarBase.add(const Duration(days: 1));
          DateTime scheduleTime = horaAcordarBase.subtract(const Duration(minutes: 60)); 
          if (scheduleTime.isAfter(now)) {
            AndroidAlarmManager.oneShotAt(scheduleTime, rotina.id.hashCode + 7, checkTrafficAndSetAlarm, exact: true, wakeup: true, alarmClock: true, allowWhileIdle: true, rescheduleOnReboot: true, params: rotina.toJson());
          }
        } else {
          for (int i = 0; i < 7; i++) {
            if (rotina.diasSemana[i]) {
              int targetWeekday = i == 0 ? 7 : i; 
              int daysDifference = targetWeekday - now.weekday;
              if (daysDifference < 0) daysDifference += 7; 
              DateTime targetDay = DateTime(now.year, now.month, now.day).add(Duration(days: daysDifference));
              DateTime horaChegada = DateTime(targetDay.year, targetDay.month, targetDay.day, rotina.horaChegada.hour, rotina.horaChegada.minute);
              DateTime horaAcordarBase = horaChegada.subtract(Duration(minutes: rotina.tempoPercursoBase + rotina.tempoPraSair));
              DateTime scheduleTime = horaAcordarBase.subtract(const Duration(minutes: 60)); 
              if (scheduleTime.isBefore(now)) scheduleTime = scheduleTime.add(const Duration(days: 7));
              AndroidAlarmManager.oneShotAt(scheduleTime, rotina.id.hashCode + i, checkTrafficAndSetAlarm, exact: true, wakeup: true, alarmClock: true, allowWhileIdle: true, rescheduleOnReboot: true, params: rotina.toJson());
            }
          }
        }
      }
    }
  }

  Widget _buildTimelineItem(String title, DateTime time, Color color, BuildContext context) {
    bool isHighlighted = color == Colors.green;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: TextStyle(fontSize: 10, color: isHighlighted ? Colors.green : Theme.of(context).textTheme.bodySmall!.color, fontWeight: isHighlighted ? FontWeight.bold : FontWeight.normal)),
        Text("${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}", style: TextStyle(fontSize: 14, color: isHighlighted ? Colors.green : Theme.of(context).textTheme.bodyLarge!.color, fontWeight: FontWeight.bold)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = Theme.of(context).colorScheme.primary;

    return Scaffold(
      body: _rotinas.isEmpty ? const Center(child: Text('Nenhuma rotina salva.')) : ListView.builder(
        itemCount: _rotinas.length,
        itemBuilder: (context, index) {
          final rotina = _rotinas[index];
          final weekDays = ['Dom', 'Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb'];
          final activeDays = [];
          for (int i = 0; i < rotina.diasSemana.length; i++) if (rotina.diasSemana[i]) activeDays.add(weekDays[i]);
          String diasTexto = activeDays.isEmpty ? "Uma vez (Próximas 24h)" : activeDays.join(', ');

          final now = DateTime.now();
          bool isOneOff = activeDays.isEmpty;
          DateTime targetChegada = DateTime(now.year, now.month, now.day, rotina.horaChegada.hour, rotina.horaChegada.minute);

          if (isOneOff) {
            if (now.isAfter(targetChegada)) targetChegada = targetChegada.add(const Duration(days: 1)); 
          } else {
            if (!rotina.diasSemana[now.weekday == 7 ? 0 : now.weekday] || now.isAfter(targetChegada)) {
              for(int i=1; i<=7; i++) {
                DateTime next = now.add(Duration(days: i));
                if (rotina.diasSemana[next.weekday == 7 ? 0 : next.weekday]) {
                  targetChegada = DateTime(next.year, next.month, next.day, rotina.horaChegada.hour, rotina.horaChegada.minute); break;
                }
              }
            }
          }

          int percursoToUse = rotina.tempoPercursoAtualizado ?? rotina.tempoPercursoBase;

          DateTime targetSaida = targetChegada.subtract(Duration(minutes: percursoToUse));
          DateTime targetAcordar = targetSaida.subtract(Duration(minutes: rotina.tempoPraSair));
          DateTime baseConsulta = targetAcordar.subtract(const Duration(minutes: 60));

          Color colorConsulta = now.isAfter(baseConsulta) ? Colors.green : Colors.transparent;
          Color colorAcordar = now.isAfter(targetAcordar) ? Colors.green : Colors.transparent;
          Color colorSaida = now.isAfter(targetSaida) ? Colors.green : Colors.transparent;
          Color colorChegada = Colors.transparent; 
          
          bool isZero = rotina.tempoPraSair == 0;

          return Card(
            margin: const EdgeInsets.all(8.0),
            child: InkWell(
              onTap: () => _editRoutine(rotina),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            rotina.nome?.isNotEmpty == true ? rotina.nome! : 'Chegada: ${rotina.horaChegada.format(context)}',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18), overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Switch(value: rotina.isActive, onChanged: (v) => _toggleRoutine(index, v), activeTrackColor: themeColor),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text('Chegada: ${rotina.horaChegada.format(context)}', style: TextStyle(fontSize: 14, color: Theme.of(context).textTheme.bodyMedium!.color)),
                    const SizedBox(height: 4),
                    Text('De: ${rotina.originAddress}\nPara: ${rotina.destAddress}', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                    const SizedBox(height: 8),
                    Text('Dias: $diasTexto', style: TextStyle(color: activeDays.isEmpty ? themeColor : Theme.of(context).textTheme.bodyLarge!.color, fontWeight: activeDays.isEmpty ? FontWeight.bold : FontWeight.normal)),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Percurso: $percursoToUse min', style: TextStyle(color: Theme.of(context).textTheme.bodySmall!.color)),
                        Text('Saída em: ${rotina.tempoPraSair} min', style: TextStyle(fontWeight: FontWeight.bold, color: themeColor)),
                      ],
                    ),
                    const SizedBox(height: 16),
                    
                    Container(
                      width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
                      decoration: BoxDecoration(color: themeColor.withOpacity(0.05), borderRadius: BorderRadius.circular(12), border: Border.all(color: themeColor.withOpacity(0.2))),
                      child: Wrap(
                        alignment: WrapAlignment.center, crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 8,
                        children: [
                          _buildTimelineItem("Consulta", baseConsulta, colorConsulta, context),
                          Icon(Icons.arrow_right_alt, color: themeColor, size: 16),
                          _buildTimelineItem("Acordar", targetAcordar, colorAcordar, context),
                          if (!isZero) Icon(Icons.arrow_right_alt, color: themeColor, size: 16),
                          if (!isZero) _buildTimelineItem("Sair", targetSaida, colorSaida, context),
                          Icon(Icons.arrow_right_alt, color: themeColor, size: 16),
                          _buildTimelineItem("Chegada", targetChegada, colorChegada, context),
                        ],
                      ),
                    ),
                    
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [ IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: () => _deleteRoutine(index)) ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class ConfiguracaoRotinaTab extends StatefulWidget {
  final Rotina? rotinaExistente;
  const ConfiguracaoRotinaTab({super.key, this.rotinaExistente});
  @override
  State<ConfiguracaoRotinaTab> createState() => _ConfiguracaoRotinaTabState();
}

class _ConfiguracaoRotinaTabState extends State<ConfiguracaoRotinaTab> {
  LatLng? _origem; LatLng? _destino;
  final TextEditingController _nomeController = TextEditingController();
  final TextEditingController _origemController = TextEditingController();
  final TextEditingController _destinoController = TextEditingController();
  final FocusNode _origemFocus = FocusNode(); final FocusNode _destinoFocus = FocusNode();
  final MapController _mapController = MapController();
  TimeOfDay _horaChegada = const TimeOfDay(hour: 8, minute: 0);
  double _tempoPraSair = 40.0;
  final List<bool> _diasSemana = List.filled(7, false);
  int? _travelTimeMinutes;
  final String _tomTomKey = "hi3ZyEHBQR74Ep4XBQjSpMKixP5MWbkV";
  
  List<Map<String, dynamic>> _favoritos = [];

  @override
  void initState() {
    super.initState();
    _loadFavorites();
    if (widget.rotinaExistente != null) {
      final rotina = widget.rotinaExistente!;
      _nomeController.text = rotina.nome ?? '';
      _origem = rotina.origem; _destino = rotina.destino;
      _origemController.text = rotina.originAddress; _destinoController.text = rotina.destAddress;
      _horaChegada = rotina.horaChegada;
      _tempoPraSair = ((rotina.tempoPraSair / 5).round() * 5.0).clamp(0.0, 120.0);
      _travelTimeMinutes = rotina.tempoPercursoBase;
      for (int i = 0; i < _diasSemana.length; i++) _diasSemana[i] = rotina.diasSemana[i];
    } else {
      _loadLastUsedAddresses();
    }
    _origemFocus.addListener(() { if (!_origemFocus.hasFocus) _geocodeAddress(_origemController.text, isOrigin: true); });
    _destinoFocus.addListener(() { if (!_destinoFocus.hasFocus) _geocodeAddress(_destinoController.text, isOrigin: false); });
    WidgetsBinding.instance.addPostFrameCallback((_) { _updateMapBounds(); });
    if (widget.rotinaExistente == null) _fetchTrafficInfo();
  }

  Future<void> _loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final favList = prefs.getStringList('favorite_places') ?? [];
    setState(() { _favoritos = favList.map((f) => jsonDecode(f) as Map<String, dynamic>).toList(); });
  }

  Future<void> _saveFavorite(String name, String address, LatLng loc) async {
    final prefs = await SharedPreferences.getInstance();
    _favoritos.add({'name': name, 'address': address, 'lat': loc.latitude, 'lng': loc.longitude});
    await prefs.setStringList('favorite_places', _favoritos.map((f) => jsonEncode(f)).toList());
    setState((){});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$name salvo nos favoritos!'), backgroundColor: Colors.green));
  }

  void _showSaveFavoriteDialog(String currentText, LatLng loc) {
    TextEditingController nameCtrl = TextEditingController();
    showDialog(context: context, builder: (context) {
      return AlertDialog(
        title: const Text("Salvar Favorito"),
        content: TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: "Nome (Ex: Casa, Trabalho)")),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancelar")),
          TextButton(onPressed: () { 
            String favName = nameCtrl.text.trim();
            if (favName.isEmpty) favName = "Favorito";
            
            String savedAddress = (currentText == "Local Atual" || currentText.isEmpty) 
                ? "Lat: ${loc.latitude.toStringAsFixed(4)}, Lng: ${loc.longitude.toStringAsFixed(4)}" 
                : currentText;
                
            _saveFavorite(favName, savedAddress, loc); 
            
            setState(() {
              if (_origem == loc) _origemController.text = favName;
              if (_destino == loc) _destinoController.text = favName;
            });

            Navigator.pop(context); 
          }, child: const Text("Salvar")),
        ],
      );
    });
  }

  void _showFavoritesModal(bool isOrigin) {
    LatLng? currentLoc = isOrigin ? _origem : _destino;
    String currentText = isOrigin ? _origemController.text : _destinoController.text;

    showModalBottomSheet(context: context, builder: (BuildContext modalContext) {
      return StatefulBuilder(
        builder: (BuildContext context, StateSetter setModalState) {
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 16.0, bottom: 8.0),
                  child: Text("Locais Favoritos", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary)),
                ),
                Expanded(
                  child: _favoritos.isEmpty
                      ? const Center(child: Text("Nenhum local favoritado.", style: TextStyle(fontSize: 16)))
                      : ListView.builder(
                          itemCount: _favoritos.length,
                          itemBuilder: (context, index) {
                            final fav = _favoritos[index];
                            return ListTile(
                              leading: const Icon(Icons.star, color: Colors.amber),
                              title: Text(fav['name']), subtitle: Text(fav['address']),
                              trailing: IconButton(
                                icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
                                onPressed: () {
                                  showDialog(
                                    context: context,
                                    builder: (BuildContext dialogContext) {
                                      return AlertDialog(
                                        content: Text('Excluir atalho "${fav['name']}"?'),
                                        actions: [
                                          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text("Cancelar")),
                                          TextButton(
                                            onPressed: () async {
                                              final prefs = await SharedPreferences.getInstance();
                                              setState(() { _favoritos.removeAt(index); }); 
                                              setModalState(() {}); 
                                              await prefs.setStringList('favorite_places', _favoritos.map((f) => jsonEncode(f)).toList());
                                              if (dialogContext.mounted) Navigator.pop(dialogContext); 
                                            },
                                            child: const Text("Excluir", style: TextStyle(color: Colors.red)),
                                          ),
                                        ],
                                      );
                                    }
                                  );
                                }
                              ),
                              onTap: () {
                                setState(() {
                                  if(isOrigin) { _origemController.text = fav['name']; _origem = LatLng(fav['lat'], fav['lng']); }
                                  else { _destinoController.text = fav['name']; _destino = LatLng(fav['lat'], fav['lng']); }
                                  _updateMapBounds();
                                  _fetchTrafficInfo();
                                });
                                Navigator.pop(modalContext);
                              },
                            );
                          },
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: currentLoc == null ? null : () {
                        Navigator.pop(modalContext);
                        _showSaveFavoriteDialog(currentText, currentLoc);
                      },
                      icon: const Icon(Icons.add, color: Colors.white),
                      label: const Text('ADICIONAR FAVORITO', style: TextStyle(color: Colors.white)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: currentLoc == null ? Colors.grey : Theme.of(context).colorScheme.primary, 
                        padding: const EdgeInsets.symmetric(vertical: 15)
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        }
      );
    });
  }

  Future<void> _useCurrentLocation(bool isOrigin) async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    setState(() {
      if (isOrigin) { _origem = LatLng(position.latitude, position.longitude); _origemController.text = "Local Atual"; }
      else { _destino = LatLng(position.latitude, position.longitude); _destinoController.text = "Local Atual"; }
      _updateMapBounds();
      _fetchTrafficInfo();
    });
  }

  Future<void> _loadLastUsedAddresses() async {
    final prefs = await SharedPreferences.getInstance();
    String lastOrigin = prefs.getString('lastOriginAddress') ?? '';
    String lastDest = prefs.getString('lastDestAddress') ?? '';
    
    setState(() { _origemController.text = lastOrigin; _destinoController.text = lastDest; });

    if (_favoritos.any((f) => f['name'] == lastOrigin)) {
      var fav = _favoritos.firstWhere((f) => f['name'] == lastOrigin);
      setState(() => _origem = LatLng(fav['lat'], fav['lng']));
    } else if (lastOrigin.isNotEmpty && lastOrigin != "Local Atual") {
      await _geocodeAddress(lastOrigin, isOrigin: true);
    }

    if (_favoritos.any((f) => f['name'] == lastDest)) {
      var fav = _favoritos.firstWhere((f) => f['name'] == lastDest);
      setState(() => _destino = LatLng(fav['lat'], fav['lng']));
    } else if (lastDest.isNotEmpty && lastDest != "Local Atual") {
      await _geocodeAddress(lastDest, isOrigin: false);
    }
  }

  @override
  void dispose() { _nomeController.dispose(); _origemController.dispose(); _destinoController.dispose(); _origemFocus.dispose(); _destinoFocus.dispose(); super.dispose(); }

  Future<void> _geocodeAddress(String address, {required bool isOrigin}) async {
    if (address.isEmpty || address == "Local Atual") return;
    
    if (_favoritos.any((f) => f['name'].toString().toLowerCase() == address.toLowerCase())) {
      var fav = _favoritos.firstWhere((f) => f['name'].toString().toLowerCase() == address.toLowerCase());
      setState(() { 
        if (isOrigin) { 
          _origem = LatLng(fav['lat'], fav['lng']); 
          _origemController.text = fav['name'];
        } else { 
          _destino = LatLng(fav['lat'], fav['lng']); 
          _destinoController.text = fav['name']; 
        } 
        _updateMapBounds(); 
      });
      _fetchTrafficInfo();
      return; 
    }

    final url = Uri.parse('https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(address)}&format=json&limit=1');
    try {
      final response = await http.get(url, headers: {'User-Agent': 'com.example.smartwakeup'});
      if (!mounted) return;
      if (response.statusCode == 200) {
        final results = jsonDecode(response.body);
        if (results.isNotEmpty) {
          final lat = double.parse(results[0]['lat']); final lon = double.parse(results[0]['lon']);
          setState(() { if (isOrigin) { _origem = LatLng(lat, lon); } else { _destino = LatLng(lat, lon); } _updateMapBounds(); });
          _fetchTrafficInfo();
        } else { _showError('Endereço não encontrado.'); }
      }
    } catch (e) { _showError('Erro de conexão.'); }
  }

  Future<void> _fetchTrafficInfo() async {
    if (_origem == null || _destino == null) return;
    final url = Uri.parse('https://api.tomtom.com/routing/1/calculateRoute/${_origem!.latitude},${_origem!.longitude}:${_destino!.latitude},${_destino!.longitude}/json?key=$_tomTomKey&departAt=now&traffic=true');
    try {
      final response = await http.get(url);
      if (!mounted) return;
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        setState(() { _travelTimeMinutes = (json['routes'][0]['summary']['travelTimeInSeconds'] / 60).round(); });
      }
    } catch (e) { /* Tenta de novo no back se falhar */ }
  }

  void _updateMapBounds() {
    if (_origem != null && _destino != null) { _mapController.fitCamera(CameraFit.bounds(bounds: LatLngBounds.fromPoints([_origem!, _destino!]), padding: const EdgeInsets.all(50.0))); } 
    else if (_origem != null) { _mapController.move(_origem!, 13.0); } else if (_destino != null) { _mapController.move(_destino!, 13.0); }
  }

  void _showError(String message) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: Colors.red)); }

  Future<void> _agendarOuSalvarRotina() async {
    if (_origem == null || _destino == null || _travelTimeMinutes == null) { _showError("Aguarde o cálculo de trânsito. (Selecione endereços válidos)"); return; }
    
    FocusScope.of(context).unfocus();
    
    final rotinaId = widget.rotinaExistente?.id ?? DateTime.now().millisecondsSinceEpoch.toString();
        
    final rotinaToSave = Rotina(
      id: rotinaId, nome: _nomeController.text.trim(), origem: _origem!, destino: _destino!, originAddress: _origemController.text, destAddress: _destinoController.text,
      horaChegada: _horaChegada, diasSemana: _diasSemana, tempoPraSair: _tempoPraSair.toInt(), tempoPercursoBase: _travelTimeMinutes!,
      tomTomKey: _tomTomKey, isActive: widget.rotinaExistente?.isActive ?? true,
    );

    final prefs = await SharedPreferences.getInstance();
    final routinesJson = prefs.getStringList('routines') ?? [];
    List<Rotina> rotinas = routinesJson.map((json) { try { return Rotina.fromJson(jsonDecode(json)); } catch (e) { return null; } }).where((r) => r != null).cast<Rotina>().toList();

    final index = rotinas.indexWhere((r) => r.id == rotinaId);
    if (index != -1) { rotinas[index] = rotinaToSave; } else { rotinas.add(rotinaToSave); }

    await prefs.setStringList('routines', rotinas.map((r) => jsonEncode(r.toJson())).toList());
    await prefs.setString('lastOriginAddress', _origemController.text);
    await prefs.setString('lastDestAddress', _destinoController.text);

    final agora = DateTime.now();
    DateTime? alvoAcordar; DateTime? alvoSair;
    bool isOneOff = !_diasSemana.contains(true);

    if (isOneOff) {
      DateTime possivelChegada = DateTime(agora.year, agora.month, agora.day, _horaChegada.hour, _horaChegada.minute);
      alvoAcordar = possivelChegada.subtract(Duration(minutes: _travelTimeMinutes! + _tempoPraSair.toInt()));
      if (alvoAcordar.isBefore(agora)) alvoAcordar = alvoAcordar.add(const Duration(days: 1));
      alvoSair = alvoAcordar.add(Duration(minutes: _tempoPraSair.toInt()));
    } else {
      for (int daysAhead = 0; daysAhead <= 7; daysAhead++) {
        DateTime checkDate = agora.add(Duration(days: daysAhead));
        int uiIndex = checkDate.weekday == 7 ? 0 : checkDate.weekday;
        if (_diasSemana[uiIndex]) {
          DateTime possivelChegada = DateTime(checkDate.year, checkDate.month, checkDate.day, _horaChegada.hour, _horaChegada.minute);
          DateTime possivelAcordar = possivelChegada.subtract(Duration(minutes: _travelTimeMinutes! + _tempoPraSair.toInt()));
          if (possivelAcordar.isAfter(agora)) {
            alvoAcordar = possivelAcordar; alvoSair = possivelAcordar.add(Duration(minutes: _tempoPraSair.toInt())); break; 
          }
        }
      }
    }

    if (alvoAcordar != null && alvoSair != null) {
      final alarmAcordarSettings = AlarmSettings(
        id: rotinaToSave.id.hashCode, dateTime: alvoAcordar, assetAudioPath: 'assets/alarm.mp3', loopAudio: true, vibrate: true,
        volumeSettings: VolumeSettings.fade(volume: 1.0, fadeDuration: const Duration(seconds: 3)),
        notificationSettings: const NotificationSettings(title: 'Smart WakeUp', body: 'Hora de Acordar!', stopButton: 'Desligar'),
        warningNotificationOnKill: true, androidFullScreenIntent: true,
      );
      await Alarm.set(alarmSettings: alarmAcordarSettings);

      if (rotinaToSave.tempoPraSair > 0) {
        final alarmSairSettings = AlarmSettings(
          id: rotinaToSave.id.hashCode + 100, dateTime: alvoSair, assetAudioPath: 'assets/alarm.mp3', loopAudio: true, vibrate: true,
          volumeSettings: VolumeSettings.fade(volume: 0.8, fadeDuration: const Duration(seconds: 3)),
          notificationSettings: const NotificationSettings(title: 'Smart WakeUp', body: 'Hora de Sair de Casa!', stopButton: 'Desligar'),
          warningNotificationOnKill: true, androidFullScreenIntent: true,
        );
        await Alarm.set(alarmSettings: alarmSairSettings);
        
        if (AppSettings.useGeofencing) {
          DateTime timeToCheck = alvoSair.subtract(const Duration(minutes: 2));
          if (timeToCheck.isAfter(agora)) {
            AndroidAlarmManager.oneShotAt(timeToCheck, rotinaToSave.id.hashCode + 200, checkGeofence, exact: true, wakeup: true, rescheduleOnReboot: true, params: rotinaToSave.toJson());
          }
        }
      }
    }

    _agendarTodasAsRotinas(rotinas);

    if (!mounted) return;
    
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Rotina salva com sucesso!'), backgroundColor: Colors.green));
    
    if (widget.rotinaExistente != null) {
      Navigator.pop(context, true);
    }
  }

  void _agendarTodasAsRotinas(List<Rotina> rotinas) {
    final now = DateTime.now();
    for (final rotina in rotinas) {
      for (int i = 0; i < 8; i++) AndroidAlarmManager.cancel(rotina.id.hashCode + i);
      if (rotina.isActive) {
        bool isOneOff = !rotina.diasSemana.contains(true);
        if (isOneOff) {
          DateTime targetChegada = DateTime(now.year, now.month, now.day, rotina.horaChegada.hour, rotina.horaChegada.minute);
          DateTime horaAcordarBase = targetChegada.subtract(Duration(minutes: rotina.tempoPercursoBase + rotina.tempoPraSair));
          if (horaAcordarBase.isBefore(now)) horaAcordarBase = horaAcordarBase.add(const Duration(days: 1));
          DateTime scheduleTime = horaAcordarBase.subtract(const Duration(minutes: 60)); 
          if (scheduleTime.isAfter(now)) AndroidAlarmManager.oneShotAt(scheduleTime, rotina.id.hashCode + 7, checkTrafficAndSetAlarm, exact: true, wakeup: true, alarmClock: true, allowWhileIdle: true, rescheduleOnReboot: true, params: rotina.toJson());
        } else {
          for (int i = 0; i < 7; i++) {
            if (rotina.diasSemana[i]) {
              int targetWeekday = i == 0 ? 7 : i; 
              int daysDifference = targetWeekday - now.weekday;
              if (daysDifference < 0) daysDifference += 7; 
              DateTime targetDay = DateTime(now.year, now.month, now.day).add(Duration(days: daysDifference));
              DateTime horaChegada = DateTime(targetDay.year, targetDay.month, targetDay.day, rotina.horaChegada.hour, rotina.horaChegada.minute);
              DateTime horaAcordarBase = horaChegada.subtract(Duration(minutes: rotina.tempoPercursoBase + rotina.tempoPraSair));
              DateTime scheduleTime = horaAcordarBase.subtract(const Duration(minutes: 60)); 
              if (scheduleTime.isBefore(now)) scheduleTime = scheduleTime.add(const Duration(days: 7));
              AndroidAlarmManager.oneShotAt(scheduleTime, rotina.id.hashCode + i, checkTrafficAndSetAlarm, exact: true, wakeup: true, alarmClock: true, allowWhileIdle: true, rescheduleOnReboot: true, params: rotina.toJson());
            }
          }
        }
      }
    }
  }

  Widget _buildAddressField({required TextEditingController controller, required FocusNode focusNode, required String label, required bool isOrigin}) {
    return TextField(
      controller: controller, focusNode: focusNode,
      decoration: InputDecoration(
        labelText: label, prefixIcon: Icon(isOrigin ? Icons.home : Icons.location_on),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(icon: const Icon(Icons.my_location, color: Colors.blue), tooltip: "Local Atual", onPressed: () => _useCurrentLocation(isOrigin)),
            IconButton(icon: const Icon(Icons.bookmark, color: Colors.orange), tooltip: "Favoritos", onPressed: () => _showFavoritesModal(isOrigin)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    String arrivalText = "Chegar às: ${_horaChegada.format(context)}";
    if (_travelTimeMinutes != null) arrivalText = "$_travelTimeMinutes min | $arrivalText";
    final themeColor = Theme.of(context).colorScheme.primary;

    final appBar = widget.rotinaExistente != null
        ? AppBar(title: const Text('Editar Rotina'), leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(context, false)))
        : null;

    return Scaffold(
      appBar: appBar,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                children: [
                  TextField(controller: _nomeController, decoration: const InputDecoration(labelText: 'Nome do Alarme (Opcional)', prefixIcon: Icon(Icons.label))),
                  const SizedBox(height: 8),
                  _buildAddressField(controller: _origemController, focusNode: _origemFocus, label: 'Origem', isOrigin: true),
                  const SizedBox(height: 8),
                  _buildAddressField(controller: _destinoController, focusNode: _destinoFocus, label: 'Destino', isOrigin: false),
                ],
              ),
            ),
            Expanded(
              child: FlutterMap(
                mapController: _mapController,
                options: MapOptions(initialCenter: const LatLng(-23.5505, -46.6333), initialZoom: 11.0),
                children: [
                  TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.example.smartwakeup'),
                  MarkerLayer(
                    markers: [
                      if (_origem != null) Marker(point: _origem!, width: 80, height: 80, child: const Icon(Icons.home, color: Colors.blue, size: 40)),
                      if (_destino != null) Marker(point: _destino!, width: 80, height: 80, child: const Icon(Icons.location_on, color: Colors.red, size: 40)),
                    ],
                  ),
                  if (_origem != null && _destino != null) PolylineLayer(polylines: [Polyline(points: [_origem!, _destino!], color: themeColor, strokeWidth: 4)]),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.all(16.0),
              decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor, boxShadow: const [BoxShadow(blurRadius: 10, color: Colors.black12)]),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      title: Text(arrivalText, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                      trailing: Icon(Icons.edit_calendar, color: themeColor),
                      onTap: () async {
                        final time = await showTimePicker(context: context, initialTime: _horaChegada);
                        if (time != null) setState(() => _horaChegada = time);
                      },
                    ),
                    const Divider(),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text("Tempo pra Sair:"),
                        DropdownButton<double>(
                          value: _tempoPraSair,
                          items: List.generate(25, (index) => index * 5.0).map<DropdownMenuItem<double>>((double value) {
                            return DropdownMenuItem<double>(value: value, child: Text('${value.toInt()} min'));
                          }).toList(),
                          onChanged: (double? newValue) { setState(() { _tempoPraSair = newValue!; }); },
                        ),
                      ],
                    ),
                    const Divider(),
                    
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: List.generate(7, (index) {
                        final weekDays = ['D', 'S', 'T', 'Q', 'Q', 'S', 'S'];
                        final isSelected = _diasSemana[index];
                        return Expanded(
                          child: GestureDetector(
                            onTap: () { setState(() { _diasSemana[index] = !isSelected; }); },
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 2),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(color: isSelected ? themeColor : (Theme.of(context).brightness == Brightness.dark ? Colors.grey[800] : Colors.grey[400]), borderRadius: BorderRadius.circular(8)),
                              child: Text(weekDays[index], textAlign: TextAlign.center, style: TextStyle(color: isSelected ? Colors.white : Theme.of(context).textTheme.bodyMedium!.color, fontWeight: FontWeight.bold, fontSize: 13)),
                            ),
                          ),
                        );
                      }),
                    ),
                    
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _agendarOuSalvarRotina, icon: const Icon(Icons.schedule, color: Colors.white),
                        label: Text(widget.rotinaExistente != null ? 'SALVAR ALTERAÇÕES' : 'AGENDAR ROTINA', style: const TextStyle(color: Colors.white)),
                        style: ElevatedButton.styleFrom(backgroundColor: themeColor, padding: const EdgeInsets.symmetric(vertical: 15)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}