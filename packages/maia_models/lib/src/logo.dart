/// A company mark. An explicit image wins. A connector slug uses One's
/// logo. A link with no image uses the logo for that domain.
String? companyLogoUrl({String? image, String? slug, String? link}) {
  final given = image?.trim();
  if (given != null && given.isNotEmpty) return given;
  final platform = slug?.trim();
  if (platform != null && platform.isNotEmpty) {
    return 'https://assets.withone.ai/connectors/'
        '${Uri.encodeComponent(platform)}.svg';
  }
  final domain = linkDomain(link);
  if (domain == null) return null;
  return 'https://www.google.com/s2/favicons?domain='
      '${Uri.encodeComponent(domain)}&sz=128';
}

/// Host of an http(s) link, without a leading www.
String? linkDomain(String? link) {
  final raw = link?.trim();
  if (raw == null || raw.isEmpty) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  if (uri.host.isEmpty) return null;
  final host = uri.host.toLowerCase();
  return host.startsWith('www.') ? host.substring(4) : host;
}
