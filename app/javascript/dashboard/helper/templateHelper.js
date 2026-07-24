import { renderTemplateFieldReferencePreview } from './templateFieldReferences';

// Constants
export const DEFAULT_LANGUAGE = 'en';
export const DEFAULT_CATEGORY = 'UTILITY';
export const COMPONENT_TYPES = {
  HEADER: 'HEADER',
  BODY: 'BODY',
  FOOTER: 'FOOTER',
  BUTTONS: 'BUTTONS',
  CAROUSEL: 'CAROUSEL',
};
export const MEDIA_FORMATS = ['IMAGE', 'VIDEO', 'DOCUMENT'];
export const UNSUPPORTED_TEMPLATE_COMPONENT_TYPES = [
  'LIST',
  'PRODUCT',
  'LIMITED_TIME_OFFER',
  'CALL_PERMISSION_REQUEST',
];
export const UNSUPPORTED_TEMPLATE_HEADER_FORMATS = ['LOCATION'];

export const findComponentByType = (template, type) =>
  template.components?.find(component => component.type === type);

export const processVariable = str => {
  return str.replace(/{{|}}/g, '');
};

export const extractTemplateVariables = text => {
  const matchedVariables = String(text || '').match(/{{([^}]+)}}/g);
  if (!matchedVariables) {
    return [];
  }

  return matchedVariables.map(variable => processVariable(variable));
};

export const allKeysRequired = value => {
  const keys = Object.keys(value);
  return keys.every(key => value[key]);
};

export const replaceTemplateVariables = (
  templateText,
  processedParams,
  { previewMode = true, section = 'body' } = {}
) => {
  return templateText.replace(/{{([^}]+)}}/g, (match, variable) => {
    const variableKey = processVariable(variable);
    const value = processedParams[section]?.[variableKey];
    if (!value) {
      return `{{${variable}}}`;
    }

    return previewMode ? renderTemplateFieldReferencePreview(value) : value;
  });
};

const buildCarouselCardParameters = (card, cardIndex) => {
  const header = findComponentByType(card, COMPONENT_TYPES.HEADER);
  const body = findComponentByType(card, COMPONENT_TYPES.BODY);
  const buttons = findComponentByType(card, COMPONENT_TYPES.BUTTONS);
  const bodyVariables = extractTemplateVariables(body?.text);

  return {
    card_index: cardIndex,
    header: {
      media_id: '',
      media_type: header?.format?.toLowerCase() || '',
    },
    body: Object.fromEntries(bodyVariables.map(variable => [variable, ''])),
    buttons: (buttons?.buttons || []).flatMap((button, buttonIndex) => {
      const type = button.type?.toLowerCase();
      const supportsParameter =
        type === 'quick_reply' ||
        (type === 'url' && button.url?.includes('{{'));
      if (!supportsParameter) return [];

      return [{ index: buttonIndex, type, parameter: '' }];
    }),
  };
};

const addInteractiveTemplateParameters = (template, allVariables) => {
  if (template.category?.toUpperCase() === 'AUTHENTICATION') return;

  const buttons = findComponentByType(template, COMPONENT_TYPES.BUTTONS);
  if (buttons?.buttons?.some(button => button.type === 'CATALOG')) {
    allVariables.catalog = { thumbnail_product_retailer_id: '' };
  }

  const carousel = findComponentByType(template, COMPONENT_TYPES.CAROUSEL);
  if (carousel) {
    allVariables.carousel = {
      cards: (carousel.cards || []).map(buildCarouselCardParameters),
    };
  }
};

export const buildTemplateParameters = (template, hasMediaHeaderValue) => {
  const allVariables = {};

  const bodyComponent = findComponentByType(template, COMPONENT_TYPES.BODY);
  const headerComponent = findComponentByType(template, COMPONENT_TYPES.HEADER);
  const bodyVariables = extractTemplateVariables(bodyComponent?.text);
  const headerVariables =
    headerComponent?.format === 'TEXT'
      ? extractTemplateVariables(headerComponent?.text)
      : [];

  if (bodyVariables.length) {
    allVariables.body = {};
    bodyVariables.forEach(variable => {
      allVariables.body[variable] = '';
    });
  }

  if (headerVariables.length) {
    allVariables.header = {};
    headerVariables.forEach(variable => {
      allVariables.header[variable] = '';
    });
  }

  if (hasMediaHeaderValue) {
    allVariables.header = {};
    allVariables.header.media_url = '';
    allVariables.header.media_type = headerComponent.format.toLowerCase();

    // For document templates, include media_name field for filename support
    if (headerComponent.format.toLowerCase() === 'document') {
      allVariables.header.media_name = '';
    }
  }

  // Process button variables
  const buttonComponents = template.components.filter(
    component => component.type === COMPONENT_TYPES.BUTTONS
  );

  buttonComponents.forEach(buttonComponent => {
    if (template.category?.toUpperCase() === 'AUTHENTICATION') return;

    if (buttonComponent.buttons) {
      buttonComponent.buttons.forEach((button, index) => {
        // Handle URL buttons with variables
        if (button.type === 'URL' && button.url && button.url.includes('{{')) {
          const buttonVars = button.url.match(/{{([^}]+)}}/g) || [];
          if (buttonVars.length > 0) {
            if (!allVariables.buttons) allVariables.buttons = [];
            allVariables.buttons[index] = {
              type: 'url',
              parameter: '',
              url: button.url,
              variables: buttonVars.map(v => processVariable(v)),
            };
          }
        }

        // Handle copy code buttons
        if (button.type === 'COPY_CODE') {
          if (!allVariables.buttons) allVariables.buttons = [];
          allVariables.buttons[index] = {
            type: 'copy_code',
            parameter: '',
          };
        }
      });
    }
  });

  addInteractiveTemplateParameters(template, allVariables);

  return allVariables;
};
