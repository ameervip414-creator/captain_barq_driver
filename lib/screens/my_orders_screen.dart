import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart' hide Order;
import 'package:firebase_auth/firebase_auth.dart';

import '../models/order_model.dart';
import '../services/firestore_stream_retry.dart';

class MyOrdersScreen extends StatefulWidget {
  const MyOrdersScreen({super.key});

  @override
  State<MyOrdersScreen> createState() => _MyOrdersScreenState();
}

class _MyOrdersScreenState extends State<MyOrdersScreen> {
  final Set<String> _completedOrderIds = <String>{};
  final Set<String> _completingOrderIds = <String>{};
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _ordersStreamInstance;

  @override
  void initState() {
    super.initState();
    _ordersStreamInstance = _ordersStream();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _ordersStream() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const Stream.empty();

    return resilientFirestoreStream<QuerySnapshot<Map<String, dynamic>>>(
      streamFactory: () => FirebaseFirestore.instance
          .collection('orders')
          .where('captainId', isEqualTo: uid)
          .snapshots(),
      initialDelay: const Duration(milliseconds: 500),
      maxDelay: const Duration(seconds: 8),
      maxAttempts: 6,
      shouldRetry: (error) {
        if (error is FirebaseException) {
          final code = error.code;
          return code == 'unavailable' ||
              code == 'deadline-exceeded' ||
              code == 'internal' ||
              code == 'network-request-failed';
        }
        final message = error.toString().toLowerCase();
        return message.contains('network') ||
            message.contains('timeout') ||
            message.contains('unavailable');
      },
    );
  }

  bool _isMyAssignedOrder(Map<String, dynamic> data) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return false;

    final assignedCaptainId = data['captainId'];
    if (assignedCaptainId != uid) return false;

    final status = data['status']?.toString() ?? '';
    if (status.isEmpty) return false;

    // إظهار الطلبات المنتهية أو قيد التوصيل الخاصة بالكابتن
    if (OrderStatusHelper.isOrderFinished(status) ||
        status == 'on_the_way' ||
        status == 'accepted') {
      return true;
    }

    final normalized = status.toLowerCase().replaceAll(RegExp(r'\s+'), '_');
    final hiddenStates = {
      'ready',
      'جاهز',
      'جاهز_للاستلام',
      'جاهز_للتسليم',
      'pending',
      'new',
      'created',
      'ordered',
      'waiting_for_driver',
      'cancelled',
      'ملغي',
    };
    return !hiddenStates.contains(normalized);
  }

  List<Order> _ordersFromSnapshot(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) {
    final docs = snapshot.docs.where((doc) {
      final data = doc.data();
      return _isMyAssignedOrder(data);
    }).toList();

    final mappedOrders = docs.map((doc) {
      final data = doc.data();
      final status = data['status']?.toString() ?? 'pending';
      final totalPrice = (data['totalAmount'] as num?)?.toDouble() ?? 0;

      final isFinished =
          OrderStatusHelper.isOrderFinished(status) ||
          status == 'completed' ||
          status == 'delivered' ||
          _completedOrderIds.contains(doc.id);

      final normalizedStatus = isFinished ? 'completed' : 'active';

      return Order(
        id: doc.id,
        customerName: data['customerName']?.toString() ?? 'زبون',
        customerPhone: data['customerPhone']?.toString() ?? 'غير متوفر',
        address: data['customerAddress']?.toString() ?? 'العنوان غير متوفر',
        mealPrice: _mealPrice(data, totalPrice),
        captainEarning: (data['captainEarning'] ?? data['deliveryFee'] ?? 0)
            .toDouble(),
        totalPrice: totalPrice,
        timeAgo: _timeAgo(data['updatedAt'] ?? data['timestamp']),
        status: normalizedStatus,
      );
    }).toList();

    mappedOrders.sort((a, b) {
      final aIsActive = a.status == 'active' ? 1 : 0;
      final bIsActive = b.status == 'active' ? 1 : 0;
      if (aIsActive != bIsActive) return bIsActive.compareTo(aIsActive);

      final aData = docs.firstWhere((doc) => doc.id == a.id).data();
      final bData = docs.firstWhere((doc) => doc.id == b.id).data();
      final aTime = _timestampToMillis(
        aData['updatedAt'] ?? aData['timestamp'],
      );
      final bTime = _timestampToMillis(
        bData['updatedAt'] ?? bData['timestamp'],
      );
      return bTime.compareTo(aTime);
    });

    return mappedOrders;
  }

  int _timestampToMillis(dynamic value) {
    if (value is Timestamp) return value.toDate().millisecondsSinceEpoch;
    if (value is DateTime) return value.millisecondsSinceEpoch;
    if (value is num) return (value * 1000).toInt();
    return 0;
  }

  double _mealPrice(Map<String, dynamic> data, double fallback) {
    final items = data['items'];
    if (items is List) {
      final total = items.fold<double>(0, (runningTotal, item) {
        if (item is! Map) return runningTotal;
        final price = (item['price'] as num?)?.toDouble() ?? 0;
        final quantity = (item['quantity'] as num?)?.toDouble() ?? 1;
        return runningTotal + price * quantity;
      });
      if (total > 0) return total;
    }
    return (data['subtotal'] as num?)?.toDouble() ?? fallback;
  }

  String _timeAgo(dynamic value) {
    if (value is Timestamp) {
      final difference = DateTime.now().difference(value.toDate());
      if (difference.inMinutes < 1) return 'الآن';
      return 'منذ ${difference.inMinutes} دقيقة';
    }
    return 'الآن';
  }

  Future<void> fetchOrders() async {}

  Future<void> _completeOrder(String orderId) async {
    if (_completingOrderIds.contains(orderId)) return;
    final driverId = FirebaseAuth.instance.currentUser?.uid;
    if (driverId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لم يتم العثور على حساب الكابتن')),
      );
      return;
    }

    setState(() {
      _completingOrderIds.add(orderId);
      _completedOrderIds.add(orderId);
    });

    try {
      final orderRef = FirebaseFirestore.instance
          .collection('orders')
          .doc(orderId);
      final captainRef = FirebaseFirestore.instance
          .collection('captains')
          .doc(driverId);
      final availableRef = FirebaseFirestore.instance
          .collection('available_captains')
          .doc(driverId);

      await FirebaseFirestore.instance.runTransaction((transaction) async {
        transaction.update(orderRef, {
          'status': 'completed',
          'deliveredAt': FieldValue.serverTimestamp(),
          'captainId': null, // تحرير الكابتن عند اكتمال الطلب
          'captain_id': null,
          'updatedAt': FieldValue.serverTimestamp(),
        });

        transaction.update(
          captainRef,
          CaptainAssignmentHelper.releaseCaptainAssignment(),
        );
        transaction.set(availableRef, {
          'uid': driverId,
          'status': 'active',
          'isAvailable': true,
          'currentOrderId': null,
          'lastSeen': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      });

      await CaptainActivityLogHelper.save(
        driverId: driverId,
        action: 'completed_order',
        orderId: orderId,
        extraData: {'status': 'completed', 'deliveryConfirmed': true},
      );
    } catch (e) {
      if (mounted) setState(() => _completedOrderIds.remove(orderId));
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('تعذر إتمام الطلب: $e')));
      }
    } finally {
      if (mounted) setState(() => _completingOrderIds.remove(orderId));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      body: SafeArea(
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _ordersStreamInstance,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting &&
                !snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.signal_wifi_connected_no_internet_4,
                      size: 48,
                      color: Colors.orange,
                    ),
                    const SizedBox(height: 12),
                    const Text('تعذر تحديث الطلبات، جارٍ إعادة المحاولة'),
                    const SizedBox(height: 8),
                    Text('${snapshot.error}'),
                  ],
                ),
              );
            }
            if (!snapshot.hasData || snapshot.data == null) {
              return const Center(child: Text('لا توجد طلبات حالياً'));
            }
            final orders = _ordersFromSnapshot(snapshot.data!);
            final summary = OrdersSummary(
              active: orders.where((order) => order.status == 'active').length,
              completed: orders
                  .where((order) => order.status == 'completed')
                  .length,
              total: orders.length,
            );
            return RefreshIndicator(
              onRefresh: fetchOrders,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const Text(
                          'طلباتي',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'سجل توصيلات اليوم',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 15.0),
                    child: Row(
                      children: [
                        _buildStatCard(
                          'إجمالي',
                          summary.total.toString(),
                          const Color(0xFFFFA726),
                        ),
                        _buildStatCard(
                          'مكتمل',
                          summary.completed.toString(),
                          const Color(0xFF66BB6A),
                        ),
                        _buildStatCard(
                          'نشط',
                          summary.active.toString(),
                          const Color(0xFFEF5350),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (orders.isEmpty)
                    SizedBox(
                      height: MediaQuery.of(context).size.height * 0.4,
                      child: _buildEmptyState(),
                    )
                  else
                    ...orders.map(
                      (order) => Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: _buildOrderCard(order),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildStatCard(String title, String count, Color color) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 5),
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          children: [
            Text(
              count,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              style: TextStyle(fontSize: 14, color: Colors.grey[700]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOrderCard(Order order) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: order.statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '#${order.id.substring(0, 5)}...',
                        style: TextStyle(color: Colors.grey[600], fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${order.mealPrice} ₪ سعر الوجبة',
                    style: const TextStyle(fontSize: 14),
                  ),
                  Text(
                    '${order.captainEarning} ₪ أجرة الكابتن',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFFFFA726),
                    ),
                  ),
                  Text(
                    '${order.totalPrice} ₪ المجموع الكلي',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            order.customerName,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(
                order.customerPhone,
                style: TextStyle(color: Colors.grey[700], fontSize: 13),
              ),
              const SizedBox(width: 4),
              Icon(Icons.phone_outlined, size: 14, color: Colors.grey[600]),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Expanded(
                child: Text(
                  order.address,
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.grey[600], fontSize: 13),
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.location_on_outlined,
                size: 14,
                color: Colors.grey[600],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              order.timeAgo,
              style: TextStyle(color: Colors.grey[500], fontSize: 12),
            ),
          ),
          if (order.status == 'active') ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _completingOrderIds.contains(order.id)
                    ? null
                    : () => _completeOrder(order.id),
                icon: _completingOrderIds.contains(order.id)
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_circle_outline),
                label: Text(
                  _completingOrderIds.contains(order.id)
                      ? 'جارٍ الإتمام...'
                      : 'تم التسليم',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inbox_outlined, size: 80, color: Colors.grey[400]),
          const SizedBox(height: 16),
          const Text(
            'لا يوجد طلبات اليوم',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            'اسحب للأسفل للتحديث',
            style: TextStyle(fontSize: 14, color: Colors.grey[500]),
          ),
        ],
      ),
    );
  }
}
