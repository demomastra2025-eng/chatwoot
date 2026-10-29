const normalizeLangCode = code => {
  if (!code) return '';
  return String(code).trim().toLowerCase().replace(/-/g, '_');
};

const primaryLangSubtag = code => normalizeLangCode(code).split('_')[0];

const normalizeButtonItem = rawBtn => {
  if (!rawBtn || typeof rawBtn !== 'object') return null;
  const type = String(rawBtn.type || 'QUICK_REPLY')
    .trim()
    .toUpperCase();
  let text = String(rawBtn.text || rawBtn.title || '').trim();
  if (!text && type === 'COPY_CODE') {
    text = 'Copy code';
  }
  if (!text) return null;

  return {
    type: type || 'QUICK_REPLY',
    text,
  };
};

const extractButtonsFromTemplate = template => {
  if (!template || !Array.isArray(template.components)) return [];
  const buttonsComp = template.components.find(
    comp =>
      comp &&
      typeof comp === 'object' &&
      String(comp.type || '').toUpperCase() === 'BUTTONS'
  );
  if (!buttonsComp || !Array.isArray(buttonsComp.buttons)) return [];

  return buttonsComp.buttons.map(normalizeButtonItem).filter(Boolean);
};

const findMatchingInboxTemplate = (templates, name, language) => {
  const targetName = String(name || '')
    .trim()
    .toLowerCase();
  if (!targetName || !Array.isArray(templates) || !templates.length) {
    return null;
  }

  const validTemplates = templates.filter(
    tpl => tpl && typeof tpl === 'object' && tpl.name
  );
  const targetLang = normalizeLangCode(language);
  const targetPrimary = primaryLangSubtag(language);

  if (targetLang) {
    const exactMatch = validTemplates.find(
      tpl =>
        String(tpl.name).trim().toLowerCase() === targetName &&
        normalizeLangCode(tpl.language) === targetLang
    );
    if (exactMatch) return exactMatch;

    const primaryMatch = validTemplates.find(
      tpl =>
        String(tpl.name).trim().toLowerCase() === targetName &&
        primaryLangSubtag(tpl.language) === targetPrimary
    );
    if (primaryMatch) return primaryMatch;
  }

  return (
    validTemplates.find(
      tpl => String(tpl.name).trim().toLowerCase() === targetName
    ) || null
  );
};

export const resolveWhatsappTemplateButtons = ({
  additionalAttributes,
  inbox,
} = {}) => {
  const attrs = additionalAttributes || {};
  const persistedButtons = attrs.templateButtons ?? attrs.template_buttons;

  if (Array.isArray(persistedButtons) && persistedButtons.length > 0) {
    const normalized = persistedButtons
      .map(normalizeButtonItem)
      .filter(Boolean);
    if (normalized.length > 0) return normalized;
  }

  const tplParams = attrs.templateParams ?? attrs.template_params;
  const tplName = tplParams?.name;
  if (!tplName) return [];

  const templates = inbox?.message_templates ?? inbox?.messageTemplates;
  const matched = findMatchingInboxTemplate(
    templates,
    tplName,
    tplParams?.language ?? tplParams?.languageCode ?? tplParams?.language_code
  );
  return extractButtonsFromTemplate(matched);
};

export const whatsappTemplateButtonIcon = type => {
  switch (String(type || '').toUpperCase()) {
    case 'URL':
      return 'i-lucide-external-link';
    case 'PHONE_NUMBER':
      return 'i-lucide-phone';
    case 'COPY_CODE':
      return 'i-lucide-copy';
    case 'FLOW':
      return 'i-lucide-workflow';
    default:
      return 'i-lucide-corner-up-left';
  }
};
