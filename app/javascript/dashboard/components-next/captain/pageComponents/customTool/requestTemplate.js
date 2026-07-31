const PARAM_NAME_PATTERN = /^[A-Za-z_][A-Za-z0-9_]*$/;

const escapeRegExp = value => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

export const templateBodyParams = params =>
  (params || []).filter(param => {
    const name = param?.name?.trim();
    const requestLocation = param?.request_location || 'template';
    return requestLocation === 'template' && PARAM_NAME_PATTERN.test(name);
  });

export const requestTemplateUsesParam = (template, paramName) => {
  const name = paramName?.trim();
  if (!template || !PARAM_NAME_PATTERN.test(name)) {
    return false;
  }

  const escapedName = escapeRegExp(name);
  const variablePattern = new RegExp(
    `{{\\s*(?:(?:params|p)\\s*\\.\\s*)?${escapedName}(?=\\s*(?:\\||}}))`
  );
  return variablePattern.test(template);
};

const templateValue = paramName => `{{ ${paramName} | json_value }}`;

const templateField = paramName =>
  `  "${paramName}": ${templateValue(paramName)}`;

export const buildRequestTemplate = params => {
  const bodyParams = templateBodyParams(params);
  if (bodyParams.length === 0) {
    return '';
  }

  const fields = bodyParams.map(param => templateField(param.name.trim()));
  return `{\n${fields.join(',\n')}\n}`;
};

export const insertRequestTemplateParam = (template, param) => {
  const paramName = param?.name?.trim();
  if (!PARAM_NAME_PATTERN.test(paramName)) {
    return { template, inserted: false, reason: 'invalid_param' };
  }

  if (requestTemplateUsesParam(template, paramName)) {
    return { template, inserted: false, reason: 'already_used' };
  }

  if (!template?.trim()) {
    return {
      template: `{\n${templateField(paramName)}\n}`,
      inserted: true,
      reason: null,
    };
  }

  const openingIndex = template.indexOf('{');
  const closingIndex = template.lastIndexOf('}');
  const trimmedTemplate = template.trim();
  if (
    openingIndex === -1 ||
    closingIndex <= openingIndex ||
    !trimmedTemplate.startsWith('{') ||
    !trimmedTemplate.endsWith('}')
  ) {
    return { template, inserted: false, reason: 'invalid_object' };
  }

  const existingFields = template.slice(openingIndex + 1, closingIndex).trim();
  const beforeClosing = template.slice(0, closingIndex).trimEnd();
  const separator = existingFields && !beforeClosing.endsWith(',') ? ',' : '';
  const trailingContent = template.slice(closingIndex);

  return {
    template: `${beforeClosing}${separator}\n${templateField(paramName)}\n${trailingContent}`,
    inserted: true,
    reason: null,
  };
};

export const insertMissingRequestTemplateParams = (template, params) => {
  const bodyParams = templateBodyParams(params);
  if (!template?.trim()) {
    return {
      template: buildRequestTemplate(bodyParams),
      inserted: bodyParams.length,
      reason: null,
    };
  }

  const result = bodyParams.reduce(
    (currentResult, param) => {
      if (currentResult.reason) {
        return currentResult;
      }

      const insertion = insertRequestTemplateParam(
        currentResult.template,
        param
      );
      if (insertion.reason === 'invalid_object') {
        return { ...currentResult, reason: insertion.reason };
      }

      return insertion.inserted
        ? {
            template: insertion.template,
            inserted: currentResult.inserted + 1,
            reason: null,
          }
        : currentResult;
    },
    { template, inserted: 0, reason: null }
  );

  return result.reason
    ? { template, inserted: 0, reason: result.reason }
    : result;
};
