const scrollTopBounds = conversationPanel => {
  const scrollHeight = Number(conversationPanel?.scrollHeight || 0);
  const clientHeight = Number(conversationPanel?.clientHeight || 0);
  return {
    min: 0,
    max: Math.max(scrollHeight - clientHeight, 0),
  };
};

const clampScrollTop = (conversationPanel, scrollTop) => {
  const { min, max } = scrollTopBounds(conversationPanel);
  const normalizedScrollTop = Number(scrollTop || 0);
  return Math.min(Math.max(normalizedScrollTop, min), max);
};

export const scrollConversationPanelToBottom = conversationPanel => {
  if (!conversationPanel) return false;

  const { max } = scrollTopBounds(conversationPanel);
  conversationPanel.scrollTop = max;
  return true;
};

export const scrollElementIntoConversationPanel = (
  conversationPanel,
  element,
  { block = 'start', offset = 24 } = {}
) => {
  if (!conversationPanel || !element) return false;

  const panelRect = conversationPanel.getBoundingClientRect();
  const elementRect = element.getBoundingClientRect();
  const currentScrollTop = Number(conversationPanel.scrollTop || 0);
  let nextScrollTop;

  if (block === 'end') {
    nextScrollTop =
      currentScrollTop + elementRect.bottom - panelRect.bottom + offset;
  } else if (block === 'center') {
    nextScrollTop =
      currentScrollTop +
      elementRect.top -
      panelRect.top -
      (conversationPanel.clientHeight - elementRect.height) / 2;
  } else {
    nextScrollTop = currentScrollTop + elementRect.top - panelRect.top - offset;
  }

  conversationPanel.scrollTop = clampScrollTop(
    conversationPanel,
    nextScrollTop
  );
  return true;
};
