import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class CaptainAssignmentHelper {
  static Map<String, dynamic> availableState({String? currentOrderId}) {
    return {
      'status': 'active',
      'isAvailable': true,
      'currentOrderId': currentOrderId ?? null,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  static Map<String, dynamic> busyState(String currentOrderId) {
    return {
      'status': 'active',
      'isAvailable': false,
      'currentOrderId': currentOrderId,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  static Map<String, dynamic> offlineState() {
    return {
      'status': 'offline',
      'isAvailable': false,
      'currentOrderId': null,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  static Map<String, dynamic> releaseCaptainAssignment() {
    return availableState();
  }
}

class CaptainActivityLogHelper {
  static Future<void> save({
    required String driverId,
    required String action,
    String? orderId,
    Map<String, dynamic>? extraData,
  }) async {
    final logRef = FirebaseFirestore.instance
        .collection('captain_activity_logs')
        .doc();

    await logRef.set({
      'uid': driverId,
      'action': action,
      'orderId': orderId,
      'details': extraData ?? <String, dynamic>{},
      'timestamp': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
      'source': 'captain_app',
    }, SetOptions(merge: true));
  }
}

class OrderStatusHelper {
  static final Set<String> _readyStates = {
    'ready',
    'accepted',
    'جاهز',
    'جاهز_للاستلام',
    'جاهز_للتسليم',
    'مستعد',
    'تم_تجهيز_الطلب',
  };

  static final Set<String> _finishedStates = {
    'completed',
    'delivered',
    'cancelled',
    'canceled',
    'rejected',
    'مكتمل',
    'تم_التسليم',
    'تم_التسليم_للعميل',
    'ملغي',
    'تم_الالغاء',
    'تم_الإلغاء',
    'تم_إلغاء_الطلب',
    'مرجع',
    'مرفوض',
  };

  static String _normalize(String? value) {
    if (value == null) return '';
    return value.toString().trim().toLowerCase().replaceAll(
      RegExp(r'\s+'),
      '_',
    );
  }

  static bool isOrderReadyForDriver(String? status) {
    final normalized = _normalize(status);
    return normalized.isNotEmpty && _readyStates.contains(normalized);
  }

  static bool isOrderFinished(String? status) {
    final normalized = _normalize(status);
    return _finishedStates.contains(normalized);
  }
}

class Order {
  final String id;
  final String customerName;
  final String customerPhone;
  final String address;
  final double mealPrice;
  final double captainEarning;
  final double totalPrice;
  final String timeAgo; // "الان", "منذ 45 دقيقة"
  final String status; // active, completed, pending
  final Color statusColor;

  Order({
    required this.id,
    required this.customerName,
    required this.customerPhone,
    required this.address,
    required this.mealPrice,
    required this.captainEarning,
    required this.totalPrice,
    required this.timeAgo,
    required this.status,
  }) : statusColor = _getStatusColor(status);

  static Color _getStatusColor(String status) {
    switch (status) {
      case 'active':
        return Colors.orange;
      case 'completed':
        return Colors.green;
      case 'pending':
        return Colors.blue;
      default:
        return Colors.grey;
    }
  }

  factory Order.fromJson(Map<String, dynamic> json) {
    return Order(
      id: json['id'] ?? '',
      customerName: json['customer_name'] ?? '',
      customerPhone: json['customer_phone'] ?? '',
      address: json['address'] ?? '',
      mealPrice: (json['price'] ?? 0).toDouble(),
      captainEarning: (json['captain_earning'] ?? 0).toDouble(),
      totalPrice: (json['total_price'] ?? json['price'] ?? 0).toDouble(),
      timeAgo: json['time_ago'] ?? '',
      status: json['status'] ?? 'pending',
    );
  }
}

class OrdersSummary {
  final int active;
  final int completed;
  final int total;

  OrdersSummary({
    required this.active,
    required this.completed,
    required this.total,
  });

  factory OrdersSummary.fromJson(Map<String, dynamic> json) {
    return OrdersSummary(
      active: json['active'] ?? 0,
      completed: json['completed'] ?? 0,
      total: json['total'] ?? 0,
    );
  }
}
