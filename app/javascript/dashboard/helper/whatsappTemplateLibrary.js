import { findComponentByType, COMPONENT_TYPES } from './templateHelper';

export const DEFAULT_TEMPLATE_LANGUAGE = 'en';
export const DEFAULT_TEMPLATE_CATEGORY = 'UTILITY';
export const MAX_TEMPLATE_BUTTONS = 3;

export const TEMPLATE_CATEGORY_OPTIONS = [
  { label: 'Utility', value: 'UTILITY' },
  { label: 'Marketing', value: 'MARKETING' },
];

export const TEMPLATE_HEADER_TYPE_OPTIONS = [
  { label: 'No header', value: 'none' },
  { label: 'Text header', value: 'text' },
  { label: 'Image header', value: 'image' },
  { label: 'Video header', value: 'video' },
  { label: 'Document header', value: 'document' },
];

export const TEMPLATE_BUTTON_TYPE_OPTIONS = [
  { label: 'Quick reply', value: 'QUICK_REPLY' },
  { label: 'URL button', value: 'URL' },
];

export const createEmptyTemplateButton = () => ({
  type: 'QUICK_REPLY',
  text: '',
  url: '',
  example: '',
});

export const createEmptyWhatsAppTemplateForm = () => ({
  name: '',
  language: DEFAULT_TEMPLATE_LANGUAGE,
  category: DEFAULT_TEMPLATE_CATEGORY,
  headerType: 'none',
  headerText: '',
  bodyText: '',
  footerText: '',
  sampleMediaUrl: '',
  bodyExamples: {},
  headerExamples: {},
  buttons: [],
});

function compareTemplateNames(left, right) {
  const leftName = String(left?.name || '');
  const rightName = String(right?.name || '');

  return leftName.localeCompare(rightName);
}

function compareTemplateVariants(left, right) {
  const leftLanguage = String(left?.language || 'en');
  const rightLanguage = String(right?.language || 'en');
  const languageComparison = leftLanguage.localeCompare(rightLanguage);

  if (languageComparison !== 0) {
    return languageComparison;
  }

  return compareTemplateNames(left, right);
}

function compactObject(value) {
  return Object.fromEntries(
    Object.entries(value || {}).filter(([, entryValue]) => entryValue?.trim?.())
  );
}

export const hasDanglingTemplateVariable = text => {
  const trimmedText = String(text || '').trim();
  if (!trimmedText) {
    return false;
  }

  return (
    /^{{\s*\d+\s*}}/.test(trimmedText) || /{{\s*\d+\s*}}$/.test(trimmedText)
  );
};

export const extractSequentialTemplateVariables = text => {
  const placeholders =
    String(text || '')
      .match(/{{\s*[^}]+\s*}}/g)
      ?.map(variable => variable.replace(/{{|}}/g, '').trim()) || [];

  if (!placeholders.length) {
    return { variables: [], error: '' };
  }

  if (!placeholders.every(value => /^\d+$/.test(value))) {
    return {
      variables: [],
      error: 'Variables must use numeric placeholders like {{1}}',
    };
  }

  const uniqueVariables = [...new Set(placeholders.map(Number))].sort(
    (left, right) => left - right
  );
  const highestVariable = uniqueVariables.at(-1);
  const expectedVariables = Array.from(
    { length: highestVariable },
    (_, index) => index + 1
  );

  if (
    uniqueVariables.length !== expectedVariables.length ||
    uniqueVariables.some((value, index) => value !== expectedVariables[index])
  ) {
    return {
      variables: [],
      error: 'Variables must be sequential without gaps',
    };
  }

  return {
    variables: uniqueVariables.map(String),
    error: '',
  };
};

export const buildWhatsAppTemplatePayload = form => {
  return {
    name: form.name.trim(),
    language: form.language,
    category: form.category,
    header_type: form.headerType,
    header_text: form.headerText.trim(),
    body_text: form.bodyText.trim(),
    footer_text: form.footerText.trim(),
    sample_media_url: form.sampleMediaUrl.trim(),
    body_examples: compactObject(form.bodyExamples),
    header_examples: compactObject(form.headerExamples),
    buttons: form.buttons.map(button => ({
      type: button.type,
      text: button.text.trim(),
      url: button.url.trim(),
      example: button.example.trim(),
    })),
  };
};

export const groupWhatsAppTemplates = templates => {
  const groupedTemplates = Array.from(templates || []).reduce(
    (acc, template) => {
      const templateName = String(template?.name || '').trim();
      if (!templateName) {
        return acc;
      }

      const existingGroup = acc.get(templateName) || [];
      existingGroup.push(template);
      acc.set(templateName, existingGroup);
      return acc;
    },
    new Map()
  );

  return [...groupedTemplates.entries()]
    .map(([name, variants]) => {
      const sortedVariants = [...variants].sort(compareTemplateVariants);
      const primaryVariant =
        sortedVariants.find(
          variant => String(variant?.status || '').toUpperCase() === 'APPROVED'
        ) || sortedVariants[0];

      return {
        name,
        category: primaryVariant?.category || sortedVariants[0]?.category || '',
        primaryVariant,
        variants: sortedVariants,
        languages: [
          ...new Set(sortedVariants.map(({ language }) => language || 'en')),
        ],
      };
    })
    .sort(compareTemplateNames);
};

export const getTemplateBodyPreview = template => {
  return findComponentByType(template, COMPONENT_TYPES.BODY)?.text || '';
};

export const getTemplateFooterPreview = template => {
  return findComponentByType(template, COMPONENT_TYPES.FOOTER)?.text || '';
};

export const getTemplateHeaderPreview = template => {
  const headerComponent = findComponentByType(template, COMPONENT_TYPES.HEADER);
  if (!headerComponent) return '';

  if (String(headerComponent.format).toUpperCase() === 'TEXT') {
    return headerComponent.text || '';
  }

  return headerComponent.format || '';
};

export const matchesWhatsAppTemplateSearch = (template, query) => {
  const normalizedQuery = query.trim().toLowerCase();
  if (!normalizedQuery) return true;

  const variants = Array.isArray(template?.variants)
    ? template.variants
    : [template].filter(Boolean);

  const searchHaystack = [
    template.name,
    ...variants.flatMap(variant => [
      variant.language,
      variant.category,
      variant.status,
      variant.rejected_reason,
      getTemplateBodyPreview(variant),
      getTemplateHeaderPreview(variant),
      getTemplateFooterPreview(variant),
    ]),
  ]
    .filter(Boolean)
    .join(' ')
    .toLowerCase();

  return searchHaystack.includes(normalizedQuery);
};

export const sortWhatsAppTemplates = templates => {
  return [...templates].sort(compareTemplateNames);
};

export const getTemplateStatusTone = status => {
  const normalizedStatus = String(status || '').toUpperCase();

  if (normalizedStatus === 'APPROVED') {
    return 'teal';
  }

  if (normalizedStatus === 'REJECTED' || normalizedStatus === 'DISABLED') {
    return 'ruby';
  }

  return 'amber';
};
