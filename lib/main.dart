import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:workmanager/workmanager.dart';
import 'package:permission_handler/permission_handler.dart';

import 'screens/home_screen.dart';
import 'services/firestore_stream_retry.dart';

// 1. اسم المهمة للخلفية
const locationTask = "locationBackgroundTask";

// 3. دالة الخلفية
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    await Firebase.initializeApp();
    String driverId = inputData?["driverId"] ?? "";
    if (driverId.isNotEmpty) {
      await sendLocationToFirebase(driverId, isBackground: true);
    }
    return Future.value(true);
  });
}

Future<void> sendLocationToFirebase(
  String driverId, {
  bool isBackground = false,
  Position? position,
}) async {
  try {
    final currentPosition =
        position ??
        await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
          ),
        );

    final locationData = {
      "location": GeoPoint(currentPosition.latitude, currentPosition.longitude),
      "lastUpdate": FieldValue.serverTimestamp(),
      "lastSeen": FieldValue.serverTimestamp(),
      "isBackground": isBackground,
    };

    final firestore = FirebaseFirestore.instance;
    final batch = firestore.batch();
    batch.set(
      firestore.collection('captains').doc(driverId),
      locationData,
      SetOptions(merge: true),
    );
    batch.set(
      firestore.collection('available_captains').doc(driverId),
      locationData,
      SetOptions(merge: true),
    );
    await batch.commit();

    debugPrint(
      "Location sent: ${currentPosition.latitude}, ${currentPosition.longitude}",
    );
  } catch (e) {
    debugPrint('[CAPTAIN_LOCATION_ERROR] $e');
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await configureFirestorePersistence();

  await Workmanager().initialize(callbackDispatcher, isInDebugMode: kDebugMode);

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Captain Barq Driver', // ضل نفسه
      theme: ThemeData(primarySwatch: Colors.orange),
      debugShowCheckedModeBanner: false,
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.hasData) {
            return const DriverHomePage();
          } else {
            return const LoginScreen();
          }
        },
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final emailController = TextEditingController();
  final passController = TextEditingController();
  bool loading = false;

  Future<void> _login() async {
    setState(() => loading = true);
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: emailController.text.trim(),
        password: passController.text.trim(),
      );
    } on FirebaseAuthException catch (e) {
      String message = "خطأ: ${e.code}"; // خليها تبين الكود
      if (e.code == 'wrong-password') message = "كلمة السر غلط";
      if (e.code == 'user-not-found') message = "الحساب غير موجود";
      if (e.code == 'invalid-credential') {
        message = "الايميل او كلمة السر غلط"; // هاي اللي طالعة عندك
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message), backgroundColor: Colors.red),
        );
      }
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.two_wheeler,
                size: 80,
                color: Colors.orange,
              ), // <-- غيرتها لدراجة
              const SizedBox(height: 20),
              const Text(
                "دخول كابتن برق - دراجة", // <-- غيرت الاسم
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 30),
              TextField(
                controller: emailController,
                decoration: const InputDecoration(
                  labelText: "الايميل",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 15),
              TextField(
                controller: passController,
                decoration: const InputDecoration(
                  labelText: "كلمة السر",
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 25),
              loading
                  ? const CircularProgressIndicator()
                  : SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange,
                        ),
                        onPressed: _login,
                        child: const Text(
                          "دخول",
                          style: TextStyle(fontSize: 18, color: Colors.white),
                        ),
                      ),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

class DriverHomePage extends StatefulWidget {
  const DriverHomePage({super.key});

  @override
  State<DriverHomePage> createState() => _DriverHomePageState();
}

class _DriverHomePageState extends State<DriverHomePage> {
  String driverId = "";
  Timer? _locationTimer;
  bool isOnline = false;
  bool _isUpdatingStatus = false;

  @override
  void initState() {
    super.initState();
    _initDriver();
    _requestPermissions();
  }

  Future<void> _syncOnlineStateFromFirestore() async {
    if (driverId.isEmpty) return;

    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('captains')
          .doc(driverId)
          .get();

      final data = snapshot.data();
      final status = data?['status']?.toString();
      final isAvailable = data?['isAvailable'] == true;
      final nextState = isAvailable || status == 'active';

      if (mounted) {
        setState(() => isOnline = nextState);
      }
    } catch (e, stackTrace) {
      debugPrint('[CAPTAIN_STATUS_SYNC_ERROR] $e');
      debugPrint('$stackTrace');
    }
  }

  Future<void> _writeCaptainPresenceState({
    required bool isAvailable,
    String? currentOrderId,
  }) async {
    final captainRef = FirebaseFirestore.instance
        .collection('captains')
        .doc(driverId);
    final availableRef = FirebaseFirestore.instance
        .collection('available_captains')
        .doc(driverId);

    final captainPayload = {
      'uid': driverId,
      'status': isAvailable ? 'active' : 'offline',
      'isAvailable': isAvailable,
      'currentOrderId': currentOrderId,
      'updatedAt': FieldValue.serverTimestamp(),
    };

    await captainRef.set(captainPayload, SetOptions(merge: true));

    if (isAvailable) {
      await availableRef.set({
        ...captainPayload,
        'lastSeen': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } else {
      await availableRef.delete();
    }
  }

  Future<void> _initDriver() async {
    User? user = FirebaseAuth.instance.currentUser;
    debugPrint('[CAPTAIN_INIT] uid=${user?.uid} email=${user?.email}');
    if (user != null) {
      driverId = user.uid;
      final baseData = {
        'status': 'offline',
        'isAvailable': false,
        'currentOrderId': null,
        'vehicle_type': 'motorcycle',
        'location': const GeoPoint(31.904, 35.485),
        'uid': driverId,
        'email': user.email,
        'name': user.email?.split('@')[0] ?? 'Captain',
      };

      await FirebaseFirestore.instance
          .collection('captains')
          .doc(driverId)
          .set(baseData, SetOptions(merge: true));

      await FirebaseFirestore.instance
          .collection('available_captains')
          .doc(driverId)
          .delete();

      if (mounted) {
        setState(() => isOnline = false);
      }
      debugPrint('[CAPTAIN_INIT_OK] captain=$driverId initialized offline');
      await _syncOnlineStateFromFirestore();
    }
  }

  Future<void> _requestPermissions() async {
    try {
      // نطلب صلاحية الموقع أثناء استخدام التطبيق أولاً
      var status = await Permission.locationWhenInUse.request();

      if (status.isGranted) {
        // بعد الموافقة، نطلب الصلاحية الدائمة والملاحظات
        await Permission.locationAlways.request();
        await Permission.notification.request();
      }
    } catch (e, stackTrace) {
      debugPrint('[CAPTAIN_PERMISSION_ERROR] $e');
      debugPrint('$stackTrace');
    }
  }

  Future<void> _toggleOnline() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      debugPrint('[CAPTAIN_STATUS_ERROR] user is null');
      return;
    }

    driverId = user.uid;

    if (_isUpdatingStatus || driverId.isEmpty) {
      debugPrint('[CAPTAIN_STATUS_ERROR] already updating or driver not ready');
      return;
    }

    final previousState = isOnline;
    final nextOnlineState = !previousState;
    final nextStatus = nextOnlineState ? 'active' : 'offline';

    if (mounted) {
      setState(() => isOnline = nextOnlineState);
    }

    _isUpdatingStatus = true;
    final captainRef = FirebaseFirestore.instance
        .collection('captains')
        .doc(driverId);

    debugPrint('[CAPTAIN_STATUS] uid=$driverId status=$nextStatus');

    try {
      await _writeCaptainPresenceState(
        isAvailable: nextOnlineState,
        currentOrderId: null,
      );

      final statusSnapshot = await captainRef.get();
      final status = statusSnapshot.data()?['status']?.toString();
      final isAvailable = statusSnapshot.data()?['isAvailable'] == true;
      final syncedState = isAvailable || status == 'active';

      if (mounted) setState(() => isOnline = syncedState);
      debugPrint(
        '[CAPTAIN_STATUS_OK] uid=$driverId requested=$nextStatus status=$status isAvailable=$isAvailable synced=$syncedState',
      );

      if (nextOnlineState) {
        _locationTimer?.cancel();
        await sendLocationToFirebase(driverId);
        _locationTimer = Timer.periodic(const Duration(seconds: 20), (_) {
          sendLocationToFirebase(driverId);
        });

        Workmanager().registerPeriodicTask(
          "1",
          locationTask,
          frequency: const Duration(minutes: 15),
          inputData: {"driverId": driverId},
        );
      } else {
        _locationTimer?.cancel();
        _locationTimer = null;
        Workmanager().cancelByUniqueName("1");
      }
    } catch (e, stackTrace) {
      debugPrint('[CAPTAIN_STATUS_ERROR] $e');
      debugPrint('$stackTrace');
      if (mounted) {
        setState(() => isOnline = previousState);
      }
    } finally {
      if (mounted) {
        _isUpdatingStatus = false;
      }
    }
  }

  @override
  void dispose() {
    _locationTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HomeScreen(isOnline: isOnline, onToggleStatus: _toggleOnline);
  }
}
