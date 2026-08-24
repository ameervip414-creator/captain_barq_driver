import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/order_model.dart';

import 'statistics_screen.dart';
import 'reviews_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  String name = "جاري التحميل...";
  String memberSince = "";
  double rating = 0.0;
  int completedOrders = 0;
  int totalKm = 0;
  double acceptanceRate = 0.0;
  bool isLoading = true; // عشان نعمل Loading
  bool isSigningOut = false;

  @override
  void initState() {
    super.initState();
    _loadCaptainData();
  }

  Future<void> _loadCaptainData() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      // 1. جيب بيانات الكابتن الاساسية
      final captainDoc = await FirebaseFirestore.instance
          .collection('captains')
          .doc(uid)
          .get();

      // 2. جيب كل الطلبات المكتملة (بكل الحالات التي تعني انتهاء الطلب بنجاح)
      final finishedSnap = await FirebaseFirestore.instance
          .collection('orders')
          .where('captain_id', isEqualTo: uid)
          .where(
            'status',
            whereIn: ['delivered', 'completed', 'تم_التسليم', 'مكتمل'],
          )
          .get();

      // 3. جيب كل الطلبات اللي انعرضت عليه (للدقة، نحسب كل الطلبات المسندة له)
      final allAssignedSnap = await FirebaseFirestore.instance
          .collection('orders')
          .where('captain_id', isEqualTo: uid)
          .get();

      if (captainDoc.exists && mounted) {
        final data = captainDoc.data()!;
        final finishedOrders = finishedSnap.docs;
        final allOrders = allAssignedSnap.docs;

        double totalRating = 0;
        int ratingCount = 0;
        double totalDistance = 0;

        for (var doc in finishedOrders) {
          var order = doc.data();
          // التقييم
          if (order['rating'] != null) {
            totalRating += (order['rating'] as num).toDouble();
            ratingCount++;
          }
          // المسافة
          totalDistance += (order['distance_km'] ?? 0.0) as num;
        }

        double finalRating = ratingCount > 0
            ? totalRating / ratingCount
            : (data['rating'] ?? 0.0).toDouble();

        int finalCompleted = finishedOrders.length;
        double finalKm = totalDistance;
        double finalAcceptance = allOrders.isNotEmpty
            ? (finalCompleted / allOrders.length) * 100
            : 0.0;

        setState(() {
          name = data['fullName'] ?? data['name'] ?? "كابتن برق";
          rating = finalRating;
          completedOrders = finalCompleted;
          totalKm = finalKm.toInt();
          acceptanceRate = finalAcceptance;
          isLoading = false;

          final createdAtValue = data['createdAt'] ?? data['timestamp'];
          DateTime? createdAt;
          if (createdAtValue is Timestamp) {
            createdAt = createdAtValue.toDate();
          } else if (createdAtValue is DateTime) {
            createdAt = createdAtValue;
          } else if (createdAtValue is String) {
            createdAt = DateTime.tryParse(createdAtValue);
          }

          memberSince = createdAt == null
              ? "سائق برق"
              : "سائق برق منذ ${createdAt.year}";
        });
      } else if (mounted) {
        setState(() => isLoading = false);
      }
    } catch (e) {
      if (mounted) setState(() => isLoading = false);
      debugPrint("[PROFILE_LOAD_ERROR] $e");
    }
  }

  Future<void> _signOut() async {
    final shouldSignOut = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تسجيل الخروج'),
        content: const Text('هل تريد تسجيل الخروج من الحساب؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text('تسجيل الخروج'),
          ),
        ],
      ),
    );

    if (shouldSignOut != true) return;

    if (mounted) setState(() => isSigningOut = true);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    try {
      if (uid != null) {
        await FirebaseFirestore.instance.collection('captains').doc(uid).set({
          'status': 'offline',
          'isAvailable': false,
          'currentOrderId': null,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        await FirebaseFirestore.instance
            .collection('available_captains')
            .doc(uid)
            .delete();

        await CaptainActivityLogHelper.save(
          driverId: uid,
          action: 'logged_out',
          extraData: {'status': 'offline', 'source': 'profile_screen'},
        );
      }
    } catch (e) {
      debugPrint('[CAPTAIN_SIGNOUT_CLEANUP_ERROR] $e');
    } finally {
      await FirebaseAuth.instance.signOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: Colors.orange)),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: [
              const SizedBox(height: 10),
              // الهيدر
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.settings),
                      onPressed: () {},
                    ),
                    Column(
                      children: [
                        Text(
                          name,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          memberSince,
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 13,
                          ),
                        ),
                        Row(
                          children: [
                            Text(
                              rating.toStringAsFixed(1),
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.star,
                              color: Colors.orange,
                              size: 16,
                            ),
                          ],
                        ),
                      ],
                    ),
                    Stack(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.orange,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(
                            name.isNotEmpty ? name[0] : "ك",
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              color: Colors.green,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // الكروت الثلاث
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: _statCard(
                        "${acceptanceRate.toStringAsFixed(0)}%",
                        "نسبة الإقبال",
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _statCard(
                        totalKm >= 1000
                            ? "${(totalKm / 1000).toStringAsFixed(1)}K"
                            : "$totalKm",
                        "كم مقطوع",
                        color: Colors.orange,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _statCard(
                        completedOrders >= 1000
                            ? "${(completedOrders / 1000).toStringAsFixed(1)}K"
                            : "$completedOrders",
                        "طلب مكتمل",
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // قائمة الخيارات
              _menuItem("إحصائياتي التفصيلية", Icons.bar_chart, () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => StatisticsScreen()),
                );
              }),
              _menuItem("التقييمات والمراجعات", Icons.star_border, () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => ReviewsScreen()),
                );
              }),
              _menuItem(
                isSigningOut ? "جاري تسجيل الخروج..." : "تسجيل الخروج",
                Icons.logout,
                isSigningOut ? () {} : _signOut,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statCard(String value, String label, {Color color = Colors.black}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _menuItem(String title, IconData icon, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Icon(icon, color: Colors.orange),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const Icon(
                Icons.arrow_back_ios_new,
                size: 16,
                color: Colors.grey,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
