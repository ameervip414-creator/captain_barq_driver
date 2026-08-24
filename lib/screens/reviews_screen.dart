import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ReviewsScreen extends StatefulWidget {
  // مهم: Stateful مش Stateless
  const ReviewsScreen({super.key});

  @override
  State<ReviewsScreen> createState() => _ReviewsScreenState();
}

class _ReviewsScreenState extends State<ReviewsScreen> {
  late final Future<List<Map<String, dynamic>>> _reviewsFuture;

  @override
  void initState() {
    super.initState();
    _reviewsFuture = _fetchReviews();
  }

  Future<List<Map<String, dynamic>>> _fetchReviews() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return [];

    final orders = FirebaseFirestore.instance.collection('orders');
    final camelCaseOrders = await orders
        .where('captainId', isEqualTo: uid)
        .get();
    final snakeCaseOrders = await orders
        .where('captain_id', isEqualTo: uid)
        .get();
    final uniqueOrders =
        <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
    for (final order in [...camelCaseOrders.docs, ...snakeCaseOrders.docs]) {
      uniqueOrders[order.id] = order;
    }

    final reviews = uniqueOrders.values
        .map((doc) => doc.data())
        .where(
          (data) => _isDelivered(data['status']) && _rating(data['rating']) > 0,
        )
        .toList();
    reviews.sort((first, second) => _date(second).compareTo(_date(first)));
    return reviews;
  }

  bool _isDelivered(dynamic value) {
    final status = value?.toString().trim().toLowerCase().replaceAll(' ', '_');
    return status == 'delivered' ||
        status == 'completed' ||
        status == 'مكتمل' ||
        status == 'تم_التسليم' ||
        status == 'تم_التسليم_للعميل';
  }

  double _rating(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  DateTime _date(Map<String, dynamic> data) {
    for (final key in ['deliveredAt', 'updatedAt', 'timestamp', 'createdAt']) {
      final value = data[key];
      if (value is Timestamp) return value.toDate();
      if (value is DateTime) return value;
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("التقييمات والمراجعات"),
        backgroundColor: Colors.orange,
        centerTitle: true,
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _reviewsFuture,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.orange),
            );
          }
          if (snap.hasError) {
            return const Center(child: Text("حدث خطأ"));
          }
          if (!snap.hasData || snap.data!.isEmpty) {
            return const Center(child: Text("لا توجد تقييمات بعد"));
          }

          final reviews = snap.data!;

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: reviews.length,
            itemBuilder: (context, index) {
              final order = reviews[index];
              final rating = _rating(order['rating']);
              final comment = order['review']?.toString() ?? "لا يوجد تعليق";
              final customerName = order['customerName']?.toString() ?? "عميل";

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 10,
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          // النجوم
                          children: List.generate(5, (i) {
                            if (i < rating.round()) {
                              // <-- هون صلحت الـ if وحطيت {}
                              return const Icon(
                                Icons.star,
                                color: Colors.orange,
                                size: 18,
                              );
                            } else {
                              return const Icon(
                                Icons.star_border,
                                color: Colors.grey,
                                size: 18,
                              );
                            }
                          }),
                        ),
                        Text(
                          customerName,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      comment,
                      textAlign: TextAlign.right,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
