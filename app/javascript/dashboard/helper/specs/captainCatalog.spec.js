import {
  extractCaptainFieldReferenceIds,
  extractCaptainToolReferenceIds,
  filterAndSortCatalogItems,
  localizeCatalogField,
  localizeCatalogTool,
  matchesCatalogSearch,
  sortCatalogItems,
} from '../captainCatalog';

describe('captainCatalog helper', () => {
  it('offers only summaries for new choices and retains used legacy fields with migration guidance', () => {
    const fields = [
      { id: 'deal.summary', field_type: 'computed', field_key: 'summary', table_name: 'deal', title: 'Сводка', selectable: true },
      { id: 'deal.title', title: 'Title', deprecated: true, selectable: false },
      { id: 'appointment.nearest', title: 'Nearest', deprecated: true, selectable: false, isUsed: true },
    ];
    const results = filterAndSortCatalogItems(fields);
    expect(results.map(field => field.id)).toEqual(['appointment.nearest', 'deal.summary']);
    expect(localizeCatalogField(fields[1], { te: () => false, t: key => key }).description).toContain('Saved legacy field');
  });

  it('localizes computed Summary titles and descriptions through their stable IDs', () => {
    const translations = {
      'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.FIELDS.DEAL.SUMMARY.TITLE': 'Summary',
      'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.FIELDS.DEAL.SUMMARY.DESCRIPTION': 'Shown X of Y in each group',
    };
    const field = localizeCatalogField(
      { id: 'deal.summary', table_name: 'deal', field_type: 'computed', field_key: 'summary', title: 'Сводка', description: 'Fallback' },
      { te: key => key in translations, t: key => translations[key] }
    );
    expect(field).toMatchObject({ title: 'Summary', description: 'Shown X of Y in each group' });
  });

  it('localizes the patient appointments group and tool', () => {
    const translations = {
      'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.GROUPS.PATIENT_APPOINTMENTS':
        'Записи пациента',
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.list_my_appointments.TITLE':
        'Мои записи',
    };
    const i18n = {
      te: key => key in translations,
      t: key => translations[key],
    };

    expect(
      localizeCatalogField(
        {
          id: 'appointment.nearest',
          title: 'Ближайшая запись',
          group_name: 'Записи пациента',
          table_name: 'appointment',
          field_type: 'computed',
          field_key: 'nearest',
        },
        i18n
      )
    ).toMatchObject({
      group_label: 'Записи пациента',
      title: 'Ближайшая запись',
    });
    const tool = localizeCatalogTool(
      { id: 'list_my_appointments', title: 'Fallback' },
      i18n
    );
    expect(tool.title).toBe('Мои записи');
  });

  it('matches search by title, description, and group labels', () => {
    const item = {
      id: 'contact.name',
      title: 'Name',
      description: 'contact.name',
      group_name: 'Contact',
      group_label: 'Contact fields',
    };

    expect(matchesCatalogSearch(item, 'name')).toBe(true);
    expect(matchesCatalogSearch(item, 'contact fields')).toBe(true);
    expect(matchesCatalogSearch(item, 'contact.name')).toBe(true);
    expect(matchesCatalogSearch(item, 'missing')).toBe(false);
  });

  it('extracts used tool and field reference ids from instructions', () => {
    const content = [
      'Use [Create Deal](tool://create_deal) when needed.',
      'Read [Phone](field://contact.phone_number) and [Status](field://conversation.status).',
      'Plain refs: tool://handoff, field://deal.amount.',
      'Duplicate [Create Deal](tool://create_deal).',
    ].join('\n');

    expect(extractCaptainToolReferenceIds(content)).toEqual([
      'create_deal',
      'handoff',
    ]);
    expect(extractCaptainFieldReferenceIds(content)).toEqual([
      'contact.phone_number',
      'conversation.status',
      'deal.amount',
    ]);
  });

  it('keeps used metadata while filtering catalog items', () => {
    const items = [
      { id: 'create_deal', title: 'Create deal', isUsed: true },
      { id: 'handoff', title: 'Handoff', isUsed: false },
    ];

    expect(
      filterAndSortCatalogItems(items, { search: 'deal' })[0]
    ).toMatchObject({ id: 'create_deal', isUsed: true });
  });

  it('sorts items by explicit group priority before alphabetical order', () => {
    const items = [
      {
        id: 'appointment.id',
        title: 'Appointment ID',
        group_name: 'Appointment',
      },
      { id: 'deal.id', title: 'Deal ID', group_name: 'Deal' },
      { id: 'contact.name', title: 'Name', group_name: 'Contact' },
      {
        id: 'conversation.id',
        title: 'Conversation ID',
        group_name: 'Conversation',
      },
    ];

    const result = sortCatalogItems(items, {
      groupOrder: ['Contact', 'Conversation', 'Appointment', 'Deal'],
    });

    expect(result.map(item => item.group_name)).toEqual([
      'Contact',
      'Conversation',
      'Appointment',
      'Deal',
    ]);
  });

  it('filters and sorts catalog items together', () => {
    const items = [
      {
        id: 'task.title',
        title: 'Title',
        description: 'task.title',
        group_name: 'Task',
      },
      {
        id: 'contact.phone_number',
        title: 'Phone Number',
        description: 'contact.phone_number',
        group_name: 'Contact',
      },
      {
        id: 'conversation.status',
        title: 'Status',
        description: 'conversation.status',
        group_name: 'Conversation',
      },
    ];

    const result = filterAndSortCatalogItems(items, {
      search: 't',
      groupOrder: ['Contact', 'Conversation', 'Task'],
    });

    expect(result.map(item => item.id)).toEqual([
      'contact.phone_number',
      'conversation.status',
      'task.title',
    ]);
  });

  it('localizes field titles and base field groups', () => {
    const field = {
      id: 'appointment.id',
      title: 'Appointment ID',
      description: 'appointment.id',
      group_name: 'Appointment',
      table_name: 'appointment',
      field_type: 'field',
      field_key: 'id',
    };
    const translations = {
      'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.FIELDS.APPOINTMENT.ID.TITLE':
        'ID записи',
      'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.APPOINTMENT.TITLE':
        'Запись',
    };
    const t = key => translations[key] || key;
    const te = key => Object.hasOwn(translations, key);

    const result = localizeCatalogField(field, { t, te });

    expect(result.title).toBe('ID записи');
    expect(result.group_label).toBe('Запись');
    expect(result.description).toBe('appointment.id');
    expect(result.id).toBe('appointment.id');
    expect(result.original_title).toBe('Appointment ID');
  });

  it('localizes tool titles and descriptions without changing tool ids', () => {
    const tool = {
      id: 'handoff',
      title: 'Handoff to Human',
      description: 'Hand off the current conversation to a human team',
      group_name: 'Conversations',
    };
    const translations = {
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.handoff.TITLE':
        'Передать человеку',
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.handoff.DESCRIPTION':
        'Передает текущий диалог живому сотруднику.',
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.GROUPS.CONVERSATIONS': 'Диалоги',
    };
    const t = key => translations[key] || key;
    const te = key => Object.hasOwn(translations, key);

    const result = localizeCatalogTool(tool, { t, te });

    expect(result.title).toBe('Передать человеку');
    expect(result.description).toBe(
      'Передает текущий диалог живому сотруднику.'
    );
    expect(result.group_label).toBe('Диалоги');
    expect(result.id).toBe('handoff');
    expect(result.original_title).toBe('Handoff to Human');
  });

  it('uses the English catalog text when the current locale lacks the tool', () => {
    const tool = {
      id: 'create_touch',
      title: 'Create Touch',
      description: 'Create a delayed outbound touch',
      group_name: 'Outbound',
    };
    const english = {
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.create_touch.TITLE':
        'Create outbound reminder',
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.create_touch.DESCRIPTION':
        'Create a scheduled outbound reminder.',
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.GROUPS.OUTBOUND': 'Outbound',
    };
    // Current locale (kk) has none of the keys; `t` falls back to English.
    const t = key => english[key] || key;
    const te = (key, locale) =>
      locale === 'en' ? Object.hasOwn(english, key) : false;

    const result = localizeCatalogTool(tool, { t, te });

    expect(result.title).toBe('Create outbound reminder');
    expect(result.description).toBe('Create a scheduled outbound reminder.');
    expect(result.title).not.toMatch(/touch/i);
    expect(result.original_title).toBe('Create Touch');
  });

  it('keeps the backend value when no locale knows the key', () => {
    const tool = { id: 'custom_tool', title: 'Custom tool', group_name: 'X' };
    const t = key => key;
    const te = () => false;

    expect(localizeCatalogTool(tool, { t, te }).title).toBe('Custom tool');
  });

  it('still matches search against original titles after localization', () => {
    const item = {
      id: 'appointment.id',
      title: 'ID записи',
      description: 'appointment.id',
      original_title: 'Appointment ID',
      group_name: 'Appointment',
    };

    expect(matchesCatalogSearch(item, 'appointment')).toBe(true);
    expect(matchesCatalogSearch(item, 'appointment.id')).toBe(true);
  });
});
