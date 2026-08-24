import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class StatisticsScreen extends StatefulWidget {
  const StatisticsScreen({super.key});

  @override
  State<StatisticsScreen> createState() => _StatisticsScreenState();
}

class _StatisticsScreenState extends State<StatisticsScreen> {
  late final Future<Map<String, dynamic>> _statisticsFuture;

  @override
  void initState() {
    super.initState();
    _statisticsFuture = _fetchStatistics();
  }

  Future<Map<String, dynamic>> _fetchStatistics() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return _emptyStatistics();

    final ordersCollection = FirebaseFirestore.instance.collection('orders');
    final camelCaseOrders = await ordersCollection
        .where('captainId', isEqualTo: uid)
        .get();
    final snakeCaseOrders = await ordersCollection
        .where('captain_id', isEqualTo: uid)
        .get();
    final orders = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
    for (final order in [...camelCaseOrders.docs, ...snakeCaseOrders.docs]) {
      orders[order.id] = order;
    }

    var completed = 0;
    var active = 0;
    var ratedOrders = 0;
    var totalRating = 0.0;
    var totalDistance = 0.0;
    var totalEarnings = 0.0;

    for (final doc in orders.values) {
      final data = doc.data();
      final status = _normalize(data['status']);
      if (_isCompleted(status)) {
        completed++;
        totalDistance += _number(data['distance_km'] ?? data['distanceKm']);
        totalEarnings += _number(
          data['captainEarning'] ??
              data['captain_earning'] ??
              data['deliveryFee'] ??
              data['delivery_fee'],
        );
        final rating = _number(data['rating']);
        if (rating > 0) {
          totalRating += rating;
          ratedOrders++;
        }
      } else if (!_isCancelled(status)) {
        active++;
      }
    }

    final total = orders.length;
    return {
      'total': total,
      'completed': completed,
      'active': active,
      'distance': totalDistance,
      'earnings': totalEarnings,
      'rating': ratedOrders == 0 ? 0.0 : totalRating / ratedOrders,
      'completionRate': total == 0 ? 0.0 : completed / total * 100,
    };
  }

  Map<String, dynamic> _emptyStatistics() => {
    'total': 0,
    'completed': 0,
    'active': 0,
    'distance': 0.0,
    'earnings': 0.0,
    'rating': 0.0,
    'completionRate': 0.0,
  };

  String _normalize(dynamic value) =>
      value?.toString().trim().toLowerCase().replaceAll(RegExp(r'\s+'), '_') ??
      '';

  bool _isCompleted(String status) => {
    'completed',
    'delivered',
    'مكتمل',
    'تم_التسليم',
    'تم_التسليم_للعميل',
  }.contains(status);

  bool _isCancelled(String status) =>
      {'cancelled', 'canceled', 'rejected', 'ملغي', 'مرفوض'}.contains(status);

  double _number(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('إحصائياتي التفصيلية'),
        backgroundColor: Colors.orange,
        centerTitle: true,
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _statisticsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.orange),
            );
          }
          if (snapshot.hasError) {
            return Center(
              child: Text('تعذر تحميل الإحصائيات: ${snapshot.error}'),
            );
          }
          final data = snapshot.data ?? _emptyStatistics();
          return _statisticsBody(data);
        },
      ),
    );
  }

  Widget _statisticsBody(Map<String, dynamic> data) {
    final completionRate = data['completionRate'] as double;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _summaryCard(data, completionRate),
        const SizedBox(height: 16),
        const Text(
          'تفاصيل الأداء',
          textAlign: TextAlign.right,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _statTile(
                'كل الطلبات',
                '${data['total']}',
                Icons.receipt_long,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _statTile(
                'المكتملة',
                '${data['completed']}',
                Icons.check_circle,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _statTile(
                'قيد التنفيذ',
                '${data['active']}',
                Icons.delivery_dining,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _statTile(
                'المسافة',
                '${(data['distance'] as double).toStringAsFixed(1)} كم',
                Icons.route,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _summaryCard(Map<String, dynamic> data, double completionRate) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.orange,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const Text('ملخص الأداء', style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 6),
          Text(
            '${(data['earnings'] as double).toStringAsFixed(0)} ₪',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Text('إجمالي الأرباح', style: TextStyle(color: Colors.white)),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${(data['rating'] as double).toStringAsFixed(1)} ★',
                style: const TextStyle(color: Colors.white, fontSize: 18),
              ),
              Text(
                '${completionRate.toStringAsFixed(0)}%',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('متوسط التقييم', style: TextStyle(color: Colors.white70)),
              Text('نسبة الإكمال', style: TextStyle(color: Colors.white70)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statTile(String title, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Icon(icon, color: Colors.orange),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          Text(title, style: const TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }
}
