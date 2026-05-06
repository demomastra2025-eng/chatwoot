import {
  filterAndSortCatalogItems,
  localizeCatalogField,
  localizeCatalogTool,
  matchesCatalogSearch,
  sortCatalogItems,
} from '../captainCatalog';

describe('captainCatalog helper', () => {
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
