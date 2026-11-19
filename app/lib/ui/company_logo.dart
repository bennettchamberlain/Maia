import 'package:maie_models/maie_models.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// A company mark from an image URL, a connector slug, or a link's domain.
/// The fallback icon is only for a missing or failed image.
class CompanyLogo extends StatelessWidget {
  const new({
    this.image,
    this.slug,
    this.link,
    this.size = 28,
    this.fallback = LucideIcons.link,
    super.key,
  });

  final String? image;
  final String? slug;
  final String? link;
  final double size;
  final IconData fallback;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final src = companyLogoUrl(image: image, slug: slug, link: link);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: theme.colorScheme.background,
        borderRadius: BorderRadius.circular(size * 0.22),
        border: Border.all(color: theme.colorScheme.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: src == null
          ? _mark(theme, fallback)
          : Padding(
              padding: EdgeInsets.all(size * 0.12),
              child: _picture(theme, src),
            ),
    );
  }

  Widget _picture(ShadThemeData theme, String src) {
    final broken = _mark(theme, fallback);
    if (src.toLowerCase().contains('.svg')) {
      return SvgPicture.network(
        src,
        width: size,
        height: size,
        placeholderBuilder: (_) => const SizedBox.shrink(),
        errorBuilder: (_, _, _) => broken,
      );
    }
    return Image.network(
      src,
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => broken,
    );
  }

  Widget _mark(ShadThemeData theme, IconData icon) => Icon(
    icon,
    size: size * 0.46,
    color: theme.colorScheme.mutedForeground,
  );
}
