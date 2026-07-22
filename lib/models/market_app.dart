class MarketApp {
  final String id;
  final String name;
  final String iconUrl;
  final String price;
  final String version;
  final String apkUrl;
  final String desc;
  final String packageName;

  const MarketApp({
    required this.id,
    required this.name,
    required this.iconUrl,
    required this.price,
    required this.version,
    required this.apkUrl,
    required this.desc,
    required this.packageName,
  });

  factory MarketApp.fromJson(Map<String, dynamic> json) {
    return MarketApp(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      iconUrl: json['icon_url']?.toString() ?? '',
      price: json['price']?.toString() ?? '免费',
      version: json['version']?.toString() ?? '',
      apkUrl: json['apk_url']?.toString() ?? '',
      desc: json['desc']?.toString() ?? '',
      packageName: json['package_name']?.toString() ?? '',
    );
  }
}