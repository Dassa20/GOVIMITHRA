import 'package:flutter_test/flutter_test.dart';
import 'package:price_prediction_app/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    expect(CropPriceApp, isNotNull);
  });
}
