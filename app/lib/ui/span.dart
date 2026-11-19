/// How many columns the window gets, following the Grok client.
///
/// A phone is one column. A narrow iPad is an icon rail and the thread.
/// A wider window adds the conversation list. The widest adds the side panel.
enum MaieSpan { stack, rail, split, desk }

/// Phone, including a large phone in landscape.
const maieStackMax = 680.0;

/// iPad portrait and a squeezed desktop window. Icon rail and thread.
const maieRailMax = 960.0;

/// iPad landscape and a medium window. List and thread.
const maieSplitMax = 1180.0;

MaieSpan maieSpan(double width) {
  if (width < maieStackMax) return MaieSpan.stack;
  if (width < maieRailMax) return MaieSpan.rail;
  if (width < maieSplitMax) return MaieSpan.split;
  return MaieSpan.desk;
}
