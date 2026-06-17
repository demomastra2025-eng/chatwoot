import { getLocalizedActivityMessage } from '../activityMessageHelper';

describe('activityMessageHelper', () => {
  const translate = (key, params = {}) => {
    const translations = {
      'CONVERSATION.ACTIVITY.CAPTAIN.AUTO_OPENED_AFTER_AGENT_REPLY':
        'Разговор был открыт автоматически после ответа сотрудника',
      'CONVERSATION.ACTIVITY.ASSIGNEE.DEFAULT_POLICY_ASSIGNED': `Назначен ответственный: ${params.assigneeName}. Инициатор: Политика по умолчанию`,
    };
    return translations[key] || key;
  };

  it('localizes legacy English captain auto-open activity content', () => {
    expect(
      getLocalizedActivityMessage(
        'Conversation was marked open automatically after an agent reply',
        translate
      )
    ).toBe('Разговор был открыт автоматически после ответа сотрудника');
  });

  it('normalizes legacy default policy assignment activity grammar', () => {
    expect(
      getLocalizedActivityMessage(
        'Политика по умолчанию назначил John ответственным',
        translate
      )
    ).toBe('Назначен ответственный: John. Инициатор: Политика по умолчанию');
  });

  it('keeps unknown activity content unchanged', () => {
    expect(getLocalizedActivityMessage('John завершил диалог', translate)).toBe(
      'John завершил диалог'
    );
  });
});
