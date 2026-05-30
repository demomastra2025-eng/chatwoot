export const getSidebarChildDisplayLabel = (child, isExpanded) => {
  if (!isExpanded && child?.collapsedLabel) {
    return child.collapsedLabel;
  }

  return child?.label || '';
};
