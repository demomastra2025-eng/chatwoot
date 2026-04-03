export const APPOINTMENT_BOOKING_INTAKE_CONTEXT = 'booking_intake';

const normalizeContexts = contexts =>
  (Array.isArray(contexts) ? contexts : [contexts])
    .map(value => String(value || '').trim())
    .filter(Boolean);

export const buildCrmFieldContextOptions = (entityKind, t) => {
  if (entityKind === 'task') {
    return [
      {
        label: t('CRM.SETTINGS.FIELDS.CONTEXTS.deal_task'),
        value: 'deal_task',
      },
      {
        label: t('CRM.SETTINGS.FIELDS.CONTEXTS.standalone_task'),
        value: 'standalone_task',
      },
    ];
  }

  if (entityKind === 'appointment') {
    return [
      {
        label: t('CRM.SETTINGS.FIELDS.CONTEXTS.booking_intake'),
        value: APPOINTMENT_BOOKING_INTAKE_CONTEXT,
      },
    ];
  }

  return [];
};

export const filterCrmFieldContexts = (contexts, entityKind, t) => {
  const allowedContexts = new Set(
    buildCrmFieldContextOptions(entityKind, t).map(option => option.value)
  );

  return normalizeContexts(contexts).filter(context =>
    allowedContexts.has(context)
  );
};

export const fieldDefinitionHasContext = (definition, context) => {
  return normalizeContexts(definition?.rules?.contexts).includes(context);
};
