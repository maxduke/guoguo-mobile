/// Queue slots follow catalog order; sparse downloads retain original slots.
/// Display episode numbers may be non-contiguous even in a complete catalog.
int? nextAdjacentEpisodeIndex(
  int index,
  int episodeCount, {
  List<int>? episodeIndices,
}) {
  if (index < 0 || index + 1 >= episodeCount) return null;
  if (episodeIndices != null &&
      episodeIndices[index + 1] != episodeIndices[index] + 1) {
    return null;
  }
  return index + 1;
}
