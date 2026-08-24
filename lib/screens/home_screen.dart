import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/order_model.dart';
import '../services/firestore_stream_retry.dart';
import 'earnings_screen.dart';
import 'my_orders_screen.dart';
import 'profile_screen.dart';

class RideRequest {
  final String orderId;
  final String customerName;
  final double price;
  final double distanceKm;
  final LatLng? customerPosition;
  final String status;

  const RideRequest({
    required this.orderId,
    required this.customerName,
    required this.price,
    required this.distanceKm,
    required this.status,
    this.customerPosition,
  });
}

class HomeScreen extends StatefulWidget {
  final bool isOnline;
  final VoidCallback? onToggleStatus;

  const HomeScreen({super.key, required this.isOnline, this.onToggleStatus});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  GoogleMapController? mapController;
  LatLng _currentPosition = const LatLng(31.904, 35.485);
  bool _locationPermissionGranted = false;
  RideRequest? _currentRequest;
  final Set<String> _rejectedOrderIds = <String>{};
  bool _isHandlingRequest = false;
  Timer? _requestTimeoutTimer;
  String? _timedRequestId;
  Stream<QuerySnapshot>? _ordersStreamInstance;

  @override
  void initState() {
    super.initState();
    if (widget.isOnline) {
      _ordersStreamInstance = _ordersStreamWithReconnect();
    }
    _getCurrentLocation();
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isOnline != widget.isOnline) {
      _ordersStreamInstance = widget.isOnline
          ? _ordersStreamWithReconnect()
          : null;
    }
  }

  Future<void> _getCurrentLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      _showLocationMessage('شغّل خدمة الموقع من إعدادات الهاتف');
      return;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      // تم نقل طلب الصلاحية لصفحة البداية لتجنب التضارب
      // لكن سنبقي هذا كإجراء احتياطي
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      _showLocationMessage('اسمح للتطبيق بالوصول إلى موقعك من الإعدادات');
      return;
    }

    try {
      // محاولة الحصول على الموقع الحالي
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
        ),
      );

      if (!mounted) return;
      setState(() {
        _locationPermissionGranted = true;
        _currentPosition = LatLng(pos.latitude, pos.longitude);
      });
      mapController?.animateCamera(CameraUpdate.newLatLng(_currentPosition));
    } catch (e) {
      debugPrint('Error getting location: $e');
    }
  }

  void _showLocationMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Stream<QuerySnapshot> _ordersStreamWithReconnect() {
    if (!widget.isOnline) {
      return const Stream.empty();
    }

    return resilientFirestoreStream<QuerySnapshot>(
      streamFactory: () {
        final driverId = FirebaseAuth.instance.currentUser?.uid;
        if (driverId == null || !mounted || !widget.isOnline) {
          return const Stream.empty();
        }

        return FirebaseFirestore.instance
            .collection('orders')
            .where('status', whereIn: ['ready', 'accepted', 'on_the_way'])
            .snapshots();
      },
      initialDelay: const Duration(milliseconds: 500),
      maxDelay: const Duration(seconds: 8),
      maxAttempts: 6,
      shouldRetry: (error) {
        if (error is FirebaseException) {
          return _isTransientFirestoreError(error);
        }
        final message = error.toString().toLowerCase();
        return message.contains('network') ||
            message.contains('timeout') ||
            message.contains('unavailable');
      },
    );
  }

  bool _isTransientFirestoreError(FirebaseException error) {
    final code = error.code;
    return code == 'unavailable' ||
        code == 'deadline-exceeded' ||
        code == 'internal' ||
        code == 'resource-exhausted' ||
        code == 'network-request-failed' ||
        code == 'aborted';
  }

  String? _captainId(Map<String, dynamic> data) {
    final value = data['captainId'] ?? data['captain_id'];
    return value?.toString();
  }

  bool _isAvailableForDriver(QueryDocumentSnapshot order) {
    final data = order.data() as Map<String, dynamic>;
    final driverId = FirebaseAuth.instance.currentUser?.uid;
    return _captainId(data) == null &&
        (data['offered_to'] == null ||
            driverId == null ||
            _containsDriver(data['offered_to'], driverId));
  }

  bool _containsDriver(dynamic value, String driverId) {
    if (value is String) return value == driverId;
    if (value is Iterable) {
      return value.any((item) => item.toString() == driverId);
    }
    if (value is Map) {
      return value.containsKey(driverId) ||
          value.values.any((item) => item == driverId);
    }
    return false;
  }

  bool _isVisibleForDriver(QueryDocumentSnapshot order) {
    final data = order.data() as Map<String, dynamic>;
    final status = data['status']?.toString();
    final captainId = _captainId(data);
    final driverId = FirebaseAuth.instance.currentUser?.uid;

    if (OrderStatusHelper.isOrderFinished(status)) return false;
    if (_rejectedOrderIds.contains(order.id)) return false;

    // إذا كان الطلب مسنداً لهذا الكابتن حصرياً، فهو مرئي دائماً له
    if (driverId != null && captainId == driverId) {
      return true;
    }

    final offeredTo = data['offered_to'];
    if (captainId == null &&
        (offeredTo == null || _containsDriver(offeredTo, driverId ?? '')) &&
        OrderStatusHelper.isOrderReadyForDriver(status)) {
      return true;
    }

    return false;
  }

  bool _isFinished(QueryDocumentSnapshot order) {
    final data = order.data() as Map<String, dynamic>;
    return OrderStatusHelper.isOrderFinished(data['status']?.toString());
  }

  double _calculateDistanceKm(LatLng start, LatLng end) {
    double distanceInMeters = Geolocator.distanceBetween(
      start.latitude,
      start.longitude,
      end.latitude,
      end.longitude,
    );
    return distanceInMeters / 1000;
  }

  RideRequest? _rideRequestFromOrder(QueryDocumentSnapshot order) {
    final orderData = order.data() as Map<String, dynamic>;
    final customerPos = _customerPosition(orderData);
    double distance = (orderData['distance'] as num?)?.toDouble() ?? 0;
    if (customerPos != null) {
      distance = _calculateDistanceKm(_currentPosition, customerPos);
    }

    return RideRequest(
      orderId: order.id,
      customerName: orderData['customerName']?.toString() ?? 'زبون',
      price: (orderData['totalAmount'] as num?)?.toDouble() ?? 0,
      distanceKm: double.parse(distance.toStringAsFixed(2)),
      status: orderData['status']?.toString() ?? 'ready',
      customerPosition: customerPos,
    );
  }

  int _orderTimestampMillis(QueryDocumentSnapshot order) {
    final data = order.data() as Map<String, dynamic>;
    for (final key in ['updatedAt', 'timestamp', 'createdAt']) {
      final value = data[key];
      if (value is Timestamp) return value.toDate().millisecondsSinceEpoch;
      if (value is DateTime) return value.millisecondsSinceEpoch;
      if (value is num) return (value * 1000).toInt();
    }
    return 0;
  }

  RideRequest? _selectCurrentRequest(List<QueryDocumentSnapshot> orders) {
    final driverId = FirebaseAuth.instance.currentUser?.uid;

    // 1. أولوية مطلقة: البحث المباشر عن الطلب الخاص بي الذي قبلته
    for (final order in orders) {
      if (_rejectedOrderIds.contains(order.id)) continue;

      final data = order.data() as Map<String, dynamic>;
      final status = data['status']?.toString();
      final captainId = _captainId(data);

      if (driverId != null && captainId == driverId) {
        if (status == 'on_the_way' ||
            status == 'accepted' ||
            status == 'ready') {
          debugPrint(
            '[STABLE_REQUEST_FOUND] Active assigned order: ${order.id} with status: $status',
          );
          return _rideRequestFromOrder(order);
        }
      }
    }

    // 2. إذا لم يكن لدي طلب حالي، نبحث عن الطلبات الجديدة المتاحة (ready)
    final candidateOrders = orders.where((order) {
      final isVisible =
          _isVisibleForDriver(order) &&
          !_isFinished(order) &&
          !_rejectedOrderIds.contains(order.id);
      if (!isVisible) return false;
      return _isAvailableForDriver(order);
    }).toList();

    candidateOrders.sort(
      (a, b) => _orderTimestampMillis(b).compareTo(_orderTimestampMillis(a)),
    );

    if (candidateOrders.isNotEmpty) {
      return _rideRequestFromOrder(candidateOrders.first);
    }

    return null;
  }

  bool _requestsDiffer(RideRequest? first, RideRequest? second) {
    if (identical(first, second)) return false;
    if (first == null || second == null) return true;
    return first.orderId != second.orderId ||
        first.status != second.status ||
        first.price != second.price ||
        first.distanceKm != second.distanceKm;
  }

  void _scheduleRequestTimeout(RideRequest? request) {
    if (request == null || request.status != 'ready') {
      _requestTimeoutTimer?.cancel();
      _requestTimeoutTimer = null;
      _timedRequestId = null;
      return;
    }
    if (_timedRequestId == request.orderId &&
        (_requestTimeoutTimer?.isActive ?? false)) {
      return;
    }
    _requestTimeoutTimer?.cancel();
    _timedRequestId = request.orderId;
    _requestTimeoutTimer = Timer(const Duration(seconds: 15), () {
      _expireUnansweredOrder(request.orderId);
    });
  }

  Future<void> _expireUnansweredOrder(String orderId) async {
    if (_currentRequest?.orderId != orderId || _isHandlingRequest) return;
    _requestTimeoutTimer = null;
    if (mounted) {
      setState(() {
        _currentRequest = null;
        _isHandlingRequest = true;
        _rejectedOrderIds.add(orderId);
      });
    }

    final orderRef = FirebaseFirestore.instance
        .collection('orders')
        .doc(orderId);
    try {
      final released = await FirebaseFirestore.instance.runTransaction<bool>((
        transaction,
      ) async {
        final snapshot = await transaction.get(orderRef);
        final data = snapshot.data();
        if (data == null ||
            !OrderStatusHelper.isOrderReadyForDriver(
              data['status']?.toString(),
            ) ||
            _captainId(data) != null) {
          return false;
        }
        transaction.update(orderRef, {
          'status': 'ready',
          'captainId': null,
          'captain_id': null,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        return true;
      });
      debugPrint('[ORDER_TIMEOUT] order=$orderId released=$released after=15s');
    } catch (e) {
      debugPrint('[ORDER_TIMEOUT_ERROR] $e');
    } finally {
      if (mounted) setState(() => _isHandlingRequest = false);
    }
  }

  LatLng? _customerPosition(Map<String, dynamic> data) {
    for (final key in ['customerLocation', 'deliveryLocation', 'location']) {
      final value = data[key];
      if (value is GeoPoint) {
        return LatLng(value.latitude, value.longitude);
      }
      if (value is Map &&
          value['latitude'] is num &&
          value['longitude'] is num) {
        return LatLng(
          (value['latitude'] as num).toDouble(),
          (value['longitude'] as num).toDouble(),
        );
      }
    }
    return null;
  }

  Future<void> _rejectOrder(String orderId) async {
    if (orderId.isEmpty || _currentRequest == null) return;
    _requestTimeoutTimer?.cancel();
    _requestTimeoutTimer = null;
    if (mounted) {
      setState(() {
        _rejectedOrderIds.add(orderId);
        _currentRequest = null;
        _isHandlingRequest = true;
      });
    }

    final driverId = FirebaseAuth.instance.currentUser?.uid;
    try {
      await _runFirestoreWithRetry(() {
        return FirebaseFirestore.instance.runTransaction((transaction) async {
          final orderRef = FirebaseFirestore.instance
              .collection('orders')
              .doc(orderId);
          final captainRef = driverId == null
              ? null
              : FirebaseFirestore.instance.collection('captains').doc(driverId);
          transaction.update(orderRef, {
            'status': 'ready',
            'captainId': null,
            'captain_id': null,
            'rejectedBy': driverId,
            'updatedAt': FieldValue.serverTimestamp(),
          });
          if (captainRef != null) {
            transaction.update(
              captainRef,
              CaptainAssignmentHelper.releaseCaptainAssignment(),
            );
          }
        });
      });

      if (driverId != null) {
        await FirebaseFirestore.instance
            .collection('available_captains')
            .doc(driverId)
            .set(
              CaptainAssignmentHelper.availableState(),
              SetOptions(merge: true),
            );
        await CaptainActivityLogHelper.save(
          driverId: driverId,
          action: 'rejected_order',
          orderId: orderId,
          extraData: {'status': 'ready', 'reason': 'driver_rejected'},
        );
      }
      if (mounted) {
        setState(() {
          _currentRequest = null;
          _isHandlingRequest = false;
        });
      }
      debugPrint('[ORDER_REJECT_OK] order=$orderId reassigned_to_pool');
    } catch (e) {
      debugPrint('[ORDER_REJECT_ERROR] $e');
      if (mounted) {
        setState(() {
          _rejectedOrderIds.remove(orderId);
          _isHandlingRequest = false;
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('تعذر رفض الطلب: $e')));
      }
    }
  }

  Future<T> _runFirestoreWithRetry<T>(Future<T> Function() operation) async {
    var retryDelay = const Duration(milliseconds: 500);
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        return await operation();
      } on FirebaseException catch (error) {
        final isTransient =
            error.code == 'unavailable' ||
            error.code == 'deadline-exceeded' ||
            error.code == 'network-request-failed';
        if (!isTransient || attempt == 2) rethrow;
        await Future.delayed(retryDelay);
        retryDelay = Duration(milliseconds: retryDelay.inMilliseconds * 2);
      }
    }
    throw StateError('Firestore operation failed after retries');
  }

  Future<void> _acceptOrder(String orderId) async {
    if (_isHandlingRequest) return;
    debugPrint('[ORDER_ACCEPT_START] order=$orderId');
    if (orderId.isEmpty || _currentRequest == null) return;
    _requestTimeoutTimer?.cancel();
    _requestTimeoutTimer = null;
    if (mounted) {
      setState(() {
        _isHandlingRequest = true;
      });
    }

    final driverId = FirebaseAuth.instance.currentUser?.uid;
    if (driverId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('خطأ: لم يتم العثور على حساب الكابتن'),
            backgroundColor: Colors.red,
          ),
        );
      }
      setState(() => _isHandlingRequest = false);
      return;
    }

    try {
      await _runFirestoreWithRetry(() {
        final batch = FirebaseFirestore.instance.batch();
        final orderRef = FirebaseFirestore.instance
            .collection('orders')
            .doc(orderId);
        final captainRef = FirebaseFirestore.instance
            .collection('captains')
            .doc(driverId);
        final availableRef = FirebaseFirestore.instance
            .collection('available_captains')
            .doc(driverId);

        batch.update(orderRef, {
          'captainId': driverId,
          'captain_id': driverId,
          'status': 'on_the_way',
          'acceptedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        batch.set(
          captainRef,
          CaptainAssignmentHelper.busyState(orderId),
          SetOptions(merge: true),
        );
        batch.set(availableRef, {
          'uid': driverId,
          'status': 'busy',
          'isAvailable': false,
          'currentOrderId': orderId,
          'lastSeen': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        return batch.commit();
      }).timeout(const Duration(seconds: 12));

      if (mounted) {
        setState(() {
          _currentRequest = RideRequest(
            orderId: _currentRequest?.orderId ?? orderId,
            customerName: _currentRequest?.customerName ?? 'زبون',
            price: _currentRequest?.price ?? 0,
            distanceKm: _currentRequest?.distanceKm ?? 0,
            customerPosition: _currentRequest?.customerPosition,
            status: 'on_the_way',
          );
          _isHandlingRequest = false;
        });
      }
      debugPrint('[ORDER_ACCEPT_OK] order=$orderId captain=$driverId');
      unawaited(
        CaptainActivityLogHelper.save(
          driverId: driverId,
          action: 'accepted_order',
          orderId: orderId,
          extraData: {'status': 'on_the_way', 'source': 'driver_app'},
        ).catchError((error) {
          debugPrint('[ACTIVITY_LOG_ERROR] $error');
        }),
      );
    } catch (e) {
      debugPrint('[ORDER_ACCEPT_ERROR] order=$orderId error=$e');
      if (mounted) {
        setState(() => _isHandlingRequest = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e is TimeoutException
                  ? 'انتهت مهلة الاتصال، تحقق من الإنترنت وحاول مرة أخرى'
                  : 'تعذر قبول الطلب: $e',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _completeOrder(String orderId) async {
    if (_isHandlingRequest) return;
    debugPrint('[ORDER_COMPLETE_START] order=$orderId');
    if (orderId.isEmpty) return;
    final driverId = FirebaseAuth.instance.currentUser?.uid;
    if (driverId == null) return;

    try {
      setState(() => _isHandlingRequest = true);

      await _runFirestoreWithRetry(() {
        final batch = FirebaseFirestore.instance.batch();
        final orderRef = FirebaseFirestore.instance
            .collection('orders')
            .doc(orderId);
        final captainRef = FirebaseFirestore.instance
            .collection('captains')
            .doc(driverId);
        final availableRef = FirebaseFirestore.instance
            .collection('available_captains')
            .doc(driverId);

        batch.update(orderRef, {
          'status': 'completed',
          'deliveredAt': FieldValue.serverTimestamp(),
          'captainId': driverId,
          'captain_id': driverId,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        batch.set(
          captainRef,
          CaptainAssignmentHelper.availableState(),
          SetOptions(merge: true),
        );
        batch.set(availableRef, {
          'uid': driverId,
          'status': 'active',
          'isAvailable': true,
          'currentOrderId': null,
          'lastSeen': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        return batch.commit();
      });

      if (mounted) {
        setState(() {
          _currentRequest = null;
          _isHandlingRequest = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تم تسليم الطلب بنجاح وأنت الآن متاح لطلب جديد'),
            backgroundColor: Colors.green,
          ),
        );
      }
      debugPrint('[ORDER_COMPLETE_OK] order=$orderId captain=$driverId');
      unawaited(
        CaptainActivityLogHelper.save(
          driverId: driverId,
          action: 'completed_order',
          orderId: orderId,
          extraData: {'status': 'completed'},
        ).catchError((error) {
          debugPrint('[ACTIVITY_LOG_ERROR] $error');
        }),
      );
    } catch (e) {
      debugPrint('[ORDER_COMPLETE_ERROR] order=$orderId error=$e');
      if (mounted) {
        setState(() => _isHandlingRequest = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('خطأ: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StreamBuilder<QuerySnapshot>(
        stream: _ordersStreamInstance,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }

          if (snapshot.hasError) {
            return Scaffold(
              body: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.signal_wifi_connected_no_internet_4,
                      size: 56,
                      color: Colors.orange,
                    ),
                    const SizedBox(height: 12),
                    const Text('تعذر اتصال البيانات حالياً'),
                    const SizedBox(height: 8),
                    Text('تفاصيل الخطأ: ${snapshot.error}'),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () => setState(() {
                        _ordersStreamInstance = _ordersStreamWithReconnect();
                      }),
                      child: const Text('إعادة المحاولة'),
                    ),
                  ],
                ),
              ),
            );
          }

          final allOrders = snapshot.data?.docs ?? <QueryDocumentSnapshot>[];
          final computedRequest = !_isHandlingRequest
              ? _selectCurrentRequest(allOrders)
              : _currentRequest;

          if (!_isHandlingRequest &&
              _requestsDiffer(_currentRequest, computedRequest)) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || _isHandlingRequest) return;
              setState(() {
                _currentRequest = computedRequest;
              });
              _scheduleRequestTimeout(computedRequest);
            });
          }
          return IndexedStack(
            index: _currentIndex,
            children: [
              _buildMapPage(),
              const MyOrdersScreen(),
              const EarningsScreen(),
              const ProfileScreen(),
            ],
          );
        },
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        selectedItemColor: Colors.orange,
        unselectedItemColor: Colors.grey,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.map), label: "الرئيسية"),
          BottomNavigationBarItem(icon: Icon(Icons.list_alt), label: "الطلبات"),
          BottomNavigationBarItem(
            icon: Icon(Icons.account_balance_wallet),
            label: "الارباح",
          ),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: "الحساب"),
        ],
      ),
    );
  }

  Widget _buildMapPage() {
    final isOnTheWay = _currentRequest?.status == 'on_the_way';
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: _currentPosition,
              zoom: 16,
            ),
            markers: {
              if (_currentRequest?.customerPosition != null)
                Marker(
                  markerId: const MarkerId('customer-location'),
                  position: _currentRequest!.customerPosition!,
                  infoWindow: const InfoWindow(title: 'موقع العميل'),
                  icon: BitmapDescriptor.defaultMarkerWithHue(
                    BitmapDescriptor.hueRed,
                  ),
                ),
            },
            myLocationEnabled: _locationPermissionGranted,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: true,
            onMapCreated: (controller) => mapController = controller,
          ),
          // زر العودة للموقع المخصص
          if (_locationPermissionGranted)
            Positioned(
              bottom: 120, // مرتفع قليلاً ليكون فوق شعار جوجل وبجانب أزرار الزوم
              right: 12,
              child: FloatingActionButton(
                mini: true,
                backgroundColor: Colors.white,
                child: const Icon(Icons.my_location, color: Colors.blue),
                onPressed: () async {
                  try {
                    final pos = await Geolocator.getCurrentPosition();
                    mapController?.animateCamera(
                      CameraUpdate.newLatLng(LatLng(pos.latitude, pos.longitude)),
                    );
                  } catch (e) {
                    debugPrint("Error moving to location: $e");
                  }
                },
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  GestureDetector(
                    onTap: widget.onToggleStatus,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: widget.isOnline
                            ? const Color(0xFFFFF3E0)
                            : const Color(0xFFF5F5F5),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: widget.isOnline ? Colors.orange : Colors.grey,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.circle,
                            color: widget.isOnline
                                ? Colors.orange
                                : Colors.grey,
                            size: 8,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            widget.isOnline ? 'متاح' : 'غير متاح',
                            style: TextStyle(
                              color: widget.isOnline
                                  ? Colors.orange[800]
                                  : Colors.grey[700],
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Row(
                    children: [
                      Text(
                        'برق',
                        style: TextStyle(
                          color: Colors.black,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(width: 4),
                      CircleAvatar(
                        backgroundColor: Colors.orange,
                        child: Icon(Icons.bolt, color: Colors.white, size: 18),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.notifications_outlined,
                      color: Colors.black,
                    ),
                    onPressed: () {},
                  ),
                ],
              ),
            ),
          ),
          if (_currentRequest != null)
            Positioned(
              bottom: 100,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 10,
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: isOnTheWay ? Colors.blue : Colors.green,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        isOnTheWay ? "قيد التوصيل" : "طلب جديد",
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _currentRequest!.customerName,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          "${_currentRequest!.distanceKm} كم",
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                        Text(
                          "${_currentRequest!.price.toStringAsFixed(2)} ₪",
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.orange,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (!isOnTheWay)
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () =>
                                  _rejectOrder(_currentRequest!.orderId),
                              child: const Text("رفض"),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.orange,
                              ),
                              onPressed: _isHandlingRequest
                                  ? null
                                  : () =>
                                        _acceptOrder(_currentRequest!.orderId),
                              child: _isHandlingRequest
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        color: Colors.white,
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Text(
                                      "قبول",
                                      style: TextStyle(color: Colors.white),
                                    ),
                            ),
                          ),
                        ],
                      )
                    else
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blue,
                          ),
                          onPressed: _isHandlingRequest
                              ? null
                              : () => _completeOrder(_currentRequest!.orderId),
                          child: _isHandlingRequest
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text(
                                  "تم التسليم",
                                  style: TextStyle(color: Colors.white),
                                ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _requestTimeoutTimer?.cancel();
    mapController?.dispose();
    super.dispose();
  }
}
