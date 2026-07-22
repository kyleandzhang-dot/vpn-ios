class RechargeTier {
  final int productId;
  final String name;
  final int price;
  final int days;
  final String badge;

  const RechargeTier({
    required this.productId,
    required this.name,
    required this.price,
    required this.days,
    this.badge = "",
  });
}

const List<RechargeTier> kRechargeTiers = [
  RechargeTier(productId: 1, name: "月度会员", price: 29, days: 30, badge: ""),
  RechargeTier(productId: 2, name: "年度会员", price: 99, days: 365, badge: "推荐"),
  RechargeTier(productId: 3, name: "永久会员", price: 198, days: 1800, badge: "推荐"),
];