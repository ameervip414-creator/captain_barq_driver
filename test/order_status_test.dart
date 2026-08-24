import 'package:flutter_test/flutter_test.dart';
import 'package:captain_barq_driver/models/order_model.dart';

void main() {
  group('Order status visibility', () {
    test('only ready-state orders are visible to the driver', () {
      expect(OrderStatusHelper.isOrderReadyForDriver('ready'), isTrue);
      expect(OrderStatusHelper.isOrderReadyForDriver('جاهز'), isTrue);
      expect(OrderStatusHelper.isOrderReadyForDriver('جاهز للاستلام'), isTrue);
      expect(OrderStatusHelper.isOrderReadyForDriver('accepted'), isTrue);
      expect(OrderStatusHelper.isOrderReadyForDriver('pending'), isFalse);
      expect(OrderStatusHelper.isOrderReadyForDriver('new'), isFalse);
      expect(OrderStatusHelper.isOrderReadyForDriver(null), isFalse);
    });

    test('marks completed states as finished', () {
      expect(OrderStatusHelper.isOrderFinished('completed'), isTrue);
      expect(OrderStatusHelper.isOrderFinished('تم التسليم'), isTrue);
      expect(OrderStatusHelper.isOrderFinished('ready'), isFalse);
      expect(OrderStatusHelper.isOrderFinished('pending'), isFalse);
    });

    test(
      'release captain assignment clears current order and marks available',
      () {
        final release = CaptainAssignmentHelper.releaseCaptainAssignment();
        expect(release['currentOrderId'], isNull);
        expect(release['isAvailable'], isTrue);
        expect(release['status'], 'active');
      },
    );
  });
}
