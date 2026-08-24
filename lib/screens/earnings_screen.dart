import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:fl_chart/fl_chart.dart';

class EarningsScreen extends StatefulWidget {
  const EarningsScreen({super.key});

  @override
  State<EarningsScreen> createState() => _EarningsScreenState();
}

class _EarningsScreenState extends State<EarningsScreen> {
  String? uid;
  late final Future<Map<String, dynamic>> _earningsFuture;

  @override
  void initState() {
    super.initState();
    uid = FirebaseAuth.instance.currentUser?.uid;
    _earningsFuture = _fetchEarnings();
  }

  Future<Map<String, dynamic>> _fetchEarnings() async {
    if (uid == null)
      return {
        'total': 0.0,
        'orders': 0,
        'rating': 0.0,
        'daily': List.filled(7, 0.0),
        'growth': 0.0,
      };

    DateTime now = DateTime.now();
    DateTime startOfWeek = now.subtract(Duration(days: now.weekday - 1));
    startOfWeek = DateTime(
      startOfWeek.year,
      startOfWeek.month,
      startOfWeek.day,
    );
    DateTime startOfLastWeek = startOfWeek.subtract(const Duration(days: 7));

    final ordersCollection = FirebaseFirestore.instance.collection('orders');
    final captainIdOrders = await ordersCollection
        .where('captainId', isEqualTo: uid)
        .get();
    final snakeCaseOrders = await ordersCollection
        .where('captain_id', isEqualTo: uid)
        .get();
    final orders = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
    for (final doc in [...captainIdOrders.docs, ...snakeCaseOrders.docs]) {
      orders[doc.id] = doc;
    }

    var captainDoc = await FirebaseFirestore.instance
        .collection('captains')
        .doc(uid)
        .get();

    double totalThisWeek = 0;
    double totalLastWeek = 0;
    List<double> daily = List.filled(7, 0.0);
    double totalRating = 0;
    int ratingCount = 0;
    int ordersCount = 0;

    for (final doc in orders.values) {
      final data = doc.data();
      if (!_isEarnedOrder(data['status'])) continue;
      final orderDate = _orderDate(data);
      if (orderDate == null) continue;
      final amount = _earningAmount(data);

      if (!orderDate.isBefore(startOfWeek)) {
        totalThisWeek += amount;
        ordersCount++;

        final dayIndex = orderDate.weekday - 1;
        if (dayIndex >= 0 && dayIndex < 7) daily[dayIndex] += amount;

        final rating = _numberValue(data['rating']);
        if (rating != null) {
          totalRating += rating;
          ratingCount++;
        }
      } else if (!orderDate.isBefore(startOfLastWeek)) {
        totalLastWeek += amount;
      }
    }

    // حساب نسبة النمو
    double growth = 0.0;
    if (totalLastWeek > 0) {
      growth = ((totalThisWeek - totalLastWeek) / totalLastWeek) * 100;
    }

    double finalRating = ratingCount > 0
        ? totalRating / ratingCount
        : (captainDoc.data()?['rating'] ?? 0.0).toDouble();

    return {
      'total': totalThisWeek,
      'orders': ordersCount,
      'rating': finalRating,
      'daily': daily,
      'growth': growth,
    };
  }

  bool _isEarnedOrder(dynamic status) {
    final normalized = status?.toString().trim().toLowerCase();
    return normalized == 'completed' ||
        normalized == 'delivered' ||
        normalized == 'مكتمل' ||
        normalized == 'تم التسليم' ||
        normalized == 'تم_التسليم' ||
        normalized == 'تم التسليم للعميل' ||
        normalized == 'تم_التسليم_للعميل';
  }

  DateTime? _orderDate(Map<String, dynamic> data) {
    for (final key in ['deliveredAt', 'updatedAt', 'timestamp', 'createdAt']) {
      final value = data[key];
      if (value is Timestamp) return value.toDate();
      if (value is DateTime) return value;
      if (value is String) {
        final parsed = DateTime.tryParse(value);
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  double _earningAmount(Map<String, dynamic> data) {
    for (final key in [
      'captainEarning',
      'captain_earning',
      'deliveryFee',
      'delivery_fee',
    ]) {
      final value = _numberValue(data[key]);
      if (value != null) return value;
    }
    return 0;
  }

  double? _numberValue(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  @override
  Widget build(BuildContext context) {
    if (uid == null) {
      return const Scaffold(body: Center(child: Text("الرجاء تسجيل الدخول")));
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: SafeArea(
        child: FutureBuilder(
          future: _earningsFuture,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(color: Colors.orange),
              );
            }
            if (snap.hasError) {
              return Center(child: Text("خطأ: ${snap.error}"));
            }
            if (!snap.hasData) {
              return const Center(child: Text("لا توجد بيانات"));
            }

            var data = snap.data!;
            List<double> daily = List<double>.from(data['daily']);
            double maxY = daily.isNotEmpty
                ? daily.reduce((a, b) => a > b ? a : b)
                : 0;
            maxY = maxY * 1.2 + 10;
            if (maxY < 100) maxY = 100;

            double growth = data['growth'];
            String growthText = growth >= 0
                ? "+${growth.toStringAsFixed(0)}%"
                : "${growth.toStringAsFixed(0)}%";
            Color growthColor = growth >= 0 ? Colors.green : Colors.red;

            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const SizedBox(height: 10),
                  const Text(
                    "الأرباح",
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                  ),
                  const Text(
                    "هذا الأسبوع",
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFFFF8A00), Color(0xFFFF6A00)],
                      ),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: growthColor.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                growthText,
                                style: TextStyle(
                                  color: growthColor,
                                  fontWeight: FontWeight.bold,
                                ),
                              ), // <-- نسبة حقيقية
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                const Text(
                                  "إجمالي الأسبوع",
                                  style: TextStyle(color: Colors.white70),
                                ),
                                Text(
                                  "${data['total'].toStringAsFixed(0)} ₪", // <-- من الداتا
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 36,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            Expanded(
                              child: _box("عدد الطلبات", "${data['orders']}"),
                            ), // <-- من الداتا
                            const SizedBox(width: 12),
                            Expanded(
                              child: _box(
                                "التقييم",
                                "${(data['rating'] as double).toStringAsFixed(1)}",
                              ),
                            ), // <-- من الداتا
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    "أرباح الأسبوع",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    height: 200,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: daily.every((e) => e == 0)
                        ? const Center(
                            child: Text(
                              "لا توجد أرباح هذا الأسبوع",
                              style: TextStyle(color: Colors.grey),
                            ),
                          )
                        : _barChart(daily, maxY),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _box(String title, String value) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.white24,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      children: [
        Text(
          title,
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    ),
  );

  Widget _barChart(List<double> daily, double maxY) {
    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: maxY,
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (v, meta) {
                const days = ['ث', 'أ', 'ا', 'خ', 'ج', 'س', 'ح'];
                return Text(
                  days[v.toInt()],
                  style: const TextStyle(fontSize: 11),
                );
              },
            ),
          ),
          leftTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
        ),
        barGroups: List.generate(
          7,
          (i) => BarChartGroupData(
            x: i,
            barRods: [
              BarChartRodData(
                toY: daily[i],
                color: i == DateTime.now().weekday - 1
                    ? Colors.orange
                    : Colors.orange.withOpacity(0.3),
                width: 22,
                borderRadius: BorderRadius.circular(8),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
