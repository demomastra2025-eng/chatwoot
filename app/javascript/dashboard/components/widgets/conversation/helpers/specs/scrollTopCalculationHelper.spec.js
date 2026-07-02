import {
  scrollConversationPanelToBottom,
  scrollElementIntoConversationPanel,
} from '../scrollTopCalculationHelper';

describe('#scrollConversationPanelToBottom', () => {
  it('scrolls to the maximum panel scrollTop', () => {
    const conversationPanel = {
      scrollHeight: 1200,
      clientHeight: 300,
      scrollTop: 0,
    };

    expect(scrollConversationPanelToBottom(conversationPanel)).toBe(true);
    expect(conversationPanel.scrollTop).toBe(900);
  });

  it('is a safe no-op without a panel', () => {
    expect(scrollConversationPanelToBottom(null)).toBe(false);
  });
});

describe('#scrollElementIntoConversationPanel', () => {
  const buildPanel = () => ({
    scrollHeight: 2000,
    clientHeight: 500,
    scrollTop: 300,
    getBoundingClientRect: () => ({ top: 100, bottom: 600 }),
  });

  it('scrolls a target element near the top of the panel', () => {
    const conversationPanel = buildPanel();
    const unreadMessage = {
      getBoundingClientRect: () => ({ top: 350, bottom: 430, height: 80 }),
    };

    expect(
      scrollElementIntoConversationPanel(conversationPanel, unreadMessage)
    ).toBe(true);
    expect(conversationPanel.scrollTop).toBe(526);
  });

  it('can align a target element with the bottom of the panel', () => {
    const conversationPanel = buildPanel();
    const labelSuggestion = {
      getBoundingClientRect: () => ({ top: 650, bottom: 720, height: 70 }),
    };

    expect(
      scrollElementIntoConversationPanel(conversationPanel, labelSuggestion, {
        block: 'end',
      })
    ).toBe(true);
    expect(conversationPanel.scrollTop).toBe(444);
  });

  it('clamps scrollTop to the available scroll range', () => {
    const conversationPanel = buildPanel();
    const unreadMessage = {
      getBoundingClientRect: () => ({ top: 3000, bottom: 3080, height: 80 }),
    };

    scrollElementIntoConversationPanel(conversationPanel, unreadMessage);

    expect(conversationPanel.scrollTop).toBe(1500);
  });
});
