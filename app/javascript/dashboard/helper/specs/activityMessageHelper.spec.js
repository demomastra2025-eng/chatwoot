import { getLocalizedActivityMessage } from '../activityMessageHelper';

describe('activityMessageHelper', () => {
  const translate = (key, params = {}) => {
    const translations = {
      'CONVERSATION.ACTIVITY.CAPTAIN.AUTO_OPENED_AFTER_AGENT_REPLY':
        'Разговор был открыт автоматически после ответа сотрудника',
      'CONVERSATION.ACTIVITY.CAPTAIN.OPEN_WITH_REASON': `Диалог был открыт ${params.userName}: ${params.reason}`,
      'CONVERSATION.ACTIVITY.ASSIGNEE.DEFAULT_POLICY_ASSIGNED': `Назначен ${params.assigneeName}`,
      'CONVERSATION.ACTIVITY.ASSIGNEE.ASSIGNED_BY': `${params.initiatorName} назначил ${params.assigneeName}`,
      'CONVERSATION.ACTIVITY.ASSIGNEE.REMOVED_BY': `${params.initiatorName} снял ответственного`,
      'CONVERSATION.ACTIVITY.ASSIGNEE.POLICY_SYSTEM': 'Система политики',
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
    ).toBe('Назначен John');
  });

  it('normalizes legacy one-line policy assignment text into single-line format', () => {
    expect(
      getLocalizedActivityMessage(
        'Назначен ответственный: Жандаулет. Инициатор: Система автоматизации через Политика по умолчанию',
        translate
      )
    ).toBe('Назначен Жандаулет');
  });

  it('hides system policy initiator from two-line or active assignment text', () => {
    expect(
      getLocalizedActivityMessage(
        'Назначен: Akhan Bakhitov.\nИнициатор: Система политики',
        translate
      )
    ).toBe('Назначен Akhan Bakhitov');
    expect(
      getLocalizedActivityMessage('Система политики назначил Асет', translate)
    ).toBe('Назначен Асет');
  });

  it('localizes AI open activity with reason', () => {
    expect(
      getLocalizedActivityMessage(
        'Conversation was marked open by Captain (Customer requested a specialist)',
        translate
      )
    ).toBe('Диалог был открыт Captain: Customer requested a specialist');
  });

  it('normalizes manual assignment text into compact single-line format', () => {
    expect(
      getLocalizedActivityMessage(
        'Назначен ответственный: Жандаулет. Инициатор: John',
        translate
      )
    ).toBe('John назначил Жандаулет');
    expect(
      getLocalizedActivityMessage(
        'Назначен: Алуа.\nИнициатор: Асет',
        translate
      )
    ).toBe('Асет назначил Алуа');
  });

  it('normalizes legacy removed assignee text into active voice', () => {
    expect(
      getLocalizedActivityMessage('Ответственный снят Асет', translate)
    ).toBe('Асет снял ответственного');
  });

  it('replaces technical label titles in activity content with display names', () => {
    expect(
      getLocalizedActivityMessage(
        'John добавил sadasd, label_31ad50d8ef40, label_f73ca8dec808',
        translate,
        {
          labels: [
            { title: 'label_31ad50d8ef40', display_title: 'VIP' },
            { title: 'label_f73ca8dec808', display_title: 'Новый клиент' },
          ],
        }
      )
    ).toBe('John добавил тег: sadasd, VIP, Новый клиент');
  });

  it('normalizes Russian label activity text to include the tag prefix', () => {
    expect(
      getLocalizedActivityMessage('John добавил второй, четвертый', translate, {
        labels: [
          { title: 'label_second', display_title: 'второй' },
          { title: 'label_fourth', display_title: 'четвертый' },
        ],
      })
    ).toBe('John добавил тег: второй, четвертый');
  });

  it('keeps unknown activity content unchanged', () => {
    expect(getLocalizedActivityMessage('John завершил диалог', translate)).toBe(
      'John завершил диалог'
    );
  });
});
