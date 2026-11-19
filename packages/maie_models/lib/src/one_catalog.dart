/// One connector the tools page can offer. Tokens stay at One.
class OneConnector {
  const OneConnector({
    required this.slug,
    required this.title,
    required this.category,
    required this.description,
    this.image,
  });

  factory OneConnector.fromJson(Map<String, dynamic> json) => OneConnector(
    slug: json['slug'] as String? ?? '',
    title: json['title'] as String? ?? '',
    category: json['category'] as String? ?? 'Other',
    description: json['description'] as String? ?? '',
    image: json['image'] as String?,
  );

  final String slug;
  final String title;
  final String category;
  final String description;
  final String? image;
}

class OneConnectorPage {
  const OneConnectorPage({
    required this.total,
    required this.categories,
    required this.connectors,
  });

  factory OneConnectorPage.fromJson(Map<String, dynamic> json) =>
      OneConnectorPage(
        total: json['total'] as int? ?? 0,
        categories: (json['categories'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(),
        connectors: (json['connectors'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(OneConnector.fromJson)
            .where((row) => row.slug.isNotEmpty)
            .toList(),
      );

  final int total;
  final List<String> categories;
  final List<OneConnector> connectors;
}
