import { describe, expect, it } from 'vitest';

import en from '../locale/en/automation.json';
import ru from '../locale/ru/automation.json';
import { AUTOMATION_RULE_EVENTS } from '../../routes/dashboard/settings/automation/constants';

const translateAutomationEvents = messages =>
  AUTOMATION_RULE_EVENTS.map(event => ({
    ...event,
    value: messages.AUTOMATION.EVENTS[event.value] || event.value,
  }));

describe('automation event translations', () => {
  it('exposes the transfer-to-AI trigger in the automation event list', () => {
    const event = AUTOMATION_RULE_EVENTS.find(
      item => item.key === 'conversation_transferred_to_ai'
    );

    expect(event).toEqual({
      key: 'conversation_transferred_to_ai',
      value: 'CONVERSATION_TRANSFERRED_TO_AI',
    });
    expect(en.AUTOMATION.EVENTS.CONVERSATION_TRANSFERRED_TO_AI).toBe(
      'Conversation transferred to AI'
    );
    expect(ru.AUTOMATION.EVENTS.CONVERSATION_TRANSFERRED_TO_AI).toBe(
      'Диалог переведён на AI'
    );
  });

  it('keeps saved resolved automation values while showing the closed label in Russian', () => {
    const resolvedEvent = AUTOMATION_RULE_EVENTS.find(
      item => item.key === 'conversation_resolved'
    );
    const translatedEvents = translateAutomationEvents(ru);

    expect(resolvedEvent).toEqual({
      key: 'conversation_resolved',
      value: 'CONVERSATION_RESOLVED',
    });
    expect(
      translatedEvents.find(item => item.key === 'conversation_resolved')?.value
    ).toBe('Диалог закрыт');
  });
});
