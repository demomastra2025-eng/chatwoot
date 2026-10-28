import { buildTemplateFieldReference } from './templateFieldReferences';

export const APPOINTMENT_PRESET_MARKER_PREFIX = '[scheduling_preset:';

export const buildPresetMarker = presetKey =>
  `${APPOINTMENT_PRESET_MARKER_PREFIX}${presetKey}]`;

export const extractPresetKeyFromRule = rule => {
  const description = String(rule?.description || '');
  const markerMatch = description.match(/\[scheduling_preset:([a-z0-9_]+)\]/i);
  if (markerMatch) {
    return markerMatch[1];
  }
  return '';
};

export const WHATSAPP_SUPPORTED_CLIENT_LANGUAGES = [
  { code: 'ru', name: 'Русский', englishName: 'Russian' },
  { code: 'kk', name: 'Қазақша', englishName: 'Kazakh' },
  { code: 'en', name: 'English', englishName: 'English' },
  { code: 'uz', name: 'Oʻzbekcha', englishName: 'Uzbek' },
  { code: 'ky', name: 'Кыргызча', englishName: 'Kyrgyz' },
  { code: 'tg', name: 'Тоҷикӣ', englishName: 'Tajik' },
  { code: 'az', name: 'Azərbaycan', englishName: 'Azerbaijani' },
  { code: 'tr', name: 'Türkçe', englishName: 'Turkish' },
  { code: 'uk', name: 'Українська', englishName: 'Ukrainian' },
  { code: 'be', name: 'Беларуская', englishName: 'Belarusian' },
  { code: 'hy', name: 'Հայերեն', englishName: 'Armenian' },
  { code: 'ka', name: 'ქართული', englishName: 'Georgian' },
  { code: 'zh_CN', name: '中文 (简体)', englishName: 'Chinese (Simplified)' },
  { code: 'ar', name: 'العربية', englishName: 'Arabic' },
  { code: 'de', name: 'Deutsch', englishName: 'German' },
  { code: 'fr', name: 'Français', englishName: 'French' },
  { code: 'es', name: 'Español', englishName: 'Spanish' },
  { code: 'it', name: 'Italiano', englishName: 'Italian' },
  { code: 'pt_BR', name: 'Português (BR)', englishName: 'Portuguese (Brazil)' },
  { code: 'ko', name: '한국어', englishName: 'Korean' },
  { code: 'ja', name: '日本語', englishName: 'Japanese' },
  { code: 'hi', name: 'हिन्दी', englishName: 'Hindi' },
  { code: 'pl', name: 'Polski', englishName: 'Polish' },
  { code: 'cs', name: 'Čeština', englishName: 'Czech' },
  { code: 'ro', name: 'Română', englishName: 'Romanian' },
  { code: 'nl', name: 'Nederlands', englishName: 'Dutch' },
  { code: 'sv', name: 'Svenska', englishName: 'Swedish' },
  { code: 'he', name: 'עברית', englishName: 'Hebrew' },
  { code: 'id', name: 'Bahasa Indonesia', englishName: 'Indonesian' },
  { code: 'ms', name: 'Bahasa Melayu', englishName: 'Malay' },
  { code: 'th', name: 'ไทย', englishName: 'Thai' },
  { code: 'vi', name: 'Tiếng Việt', englishName: 'Vietnamese' },
  { code: 'fa', name: 'فارسی', englishName: 'Persian' },
];

const LANGUAGE_ALIASES = {
  kz: 'kk',
  kaz: 'kk',
  rus: 'ru',
  eng: 'en',
  en_us: 'en',
  en_gb: 'en',
  zh: 'zh_CN',
  zh_cn: 'zh_CN',
  pt: 'pt_BR',
  pt_br: 'pt_BR',
};

export const normalizeClientLanguageCode = raw => {
  const cleaned = String(raw || '').trim();
  if (!cleaned) return '';

  const exact = WHATSAPP_SUPPORTED_CLIENT_LANGUAGES.find(
    item => item.code.toLowerCase() === cleaned.toLowerCase()
  );
  if (exact) return exact.code;

  const alias = LANGUAGE_ALIASES[cleaned.toLowerCase().replace(/-/g, '_')];
  if (alias) return alias;

  const base = cleaned.split(/[-_]/)[0].toLowerCase();
  const baseMatch = WHATSAPP_SUPPORTED_CLIENT_LANGUAGES.find(
    item => item.code.toLowerCase() === base
  );
  return baseMatch ? baseMatch.code : '';
};

export const normalizeClientLanguagesList = (
  rawList,
  fallback = ['ru', 'kk']
) => {
  const list = Array.isArray(rawList) ? rawList : [];
  const normalized = [
    ...new Set(list.map(normalizeClientLanguageCode).filter(Boolean)),
  ];
  return normalized.length ? normalized : [...fallback];
};

export const getClientLanguageNativeName = code => {
  const normalized = normalizeClientLanguageCode(code);
  const found = WHATSAPP_SUPPORTED_CLIENT_LANGUAGES.find(
    item => item.code === normalized
  );
  return found ? found.name : String(code || '').toUpperCase();
};

export const getClientLanguageLabel = code => {
  const normalized = normalizeClientLanguageCode(code);
  const found = WHATSAPP_SUPPORTED_CLIENT_LANGUAGES.find(
    item => item.code === normalized
  );
  return found
    ? `${found.name} (${found.code})`
    : String(code || '').toUpperCase();
};

export const PROMOTIONAL_STOP_WORDS = [
  'скидк',
  'акци',
  'распродаж',
  'промокод',
  'бонус',
  'подарок',
  'купон',
  'выгодно',
  'спецпредложен',
  'бесплатн',
  'жеңілдік',
  'науқан',
  'сыйлық',
  'тегін',
  'бонустар',
  'discount',
  'promo',
  'sale',
  'cashback',
  'free',
  'offer',
  'deal',
  'coupon',
];

export const APPOINTMENT_SEMANTIC_VARIABLES = [
  {
    key: 'client_name',
    token: '{{имя клиента}}',
    fieldId: 'appointment.client_name',
    fieldTitle: 'Имя клиента',
    labelKey: 'SCHEDULING.REMINDERS.VARIABLES.CLIENT_NAME',
    defaultLabel: 'Имя клиента',
    example: 'Анна',
    aliases: [
      'имя клиента',
      'имя',
      'клиент',
      'client_name',
      'contact_name',
      'contact.name',
      'appointment.client_name',
    ],
  },
  {
    key: 'appointment_date',
    token: '{{дата записи}}',
    fieldId: 'appointment.start_date',
    fieldTitle: 'Дата записи',
    labelKey: 'SCHEDULING.REMINDERS.VARIABLES.APPOINTMENT_DATE',
    defaultLabel: 'Дата записи',
    example: '25.08.2026',
    aliases: [
      'дата записи',
      'дата',
      'дата визита',
      'appointment_date',
      'start_date',
      'appointment.start_date',
    ],
  },
  {
    key: 'appointment_time',
    token: '{{время записи}}',
    fieldId: 'appointment.start_time',
    fieldTitle: 'Время записи',
    labelKey: 'SCHEDULING.REMINDERS.VARIABLES.APPOINTMENT_TIME',
    defaultLabel: 'Время записи',
    example: '15:30',
    aliases: [
      'время записи',
      'время',
      'время визита',
      'appointment_time',
      'start_time',
      'appointment.start_time',
    ],
  },
  {
    key: 'specialist_name',
    token: '{{специалист}}',
    fieldId: 'appointment.resource_name',
    fieldTitle: 'Специалист',
    labelKey: 'SCHEDULING.REMINDERS.VARIABLES.SPECIALIST_NAME',
    defaultLabel: 'Специалист',
    example: 'Алия Серикова',
    aliases: [
      'специалист',
      'исполнитель',
      'мастер',
      'врач',
      'specialist_name',
      'resource_name',
      'appointment.resource_name',
    ],
  },
  {
    key: 'service_name',
    token: '{{услуга}}',
    fieldId: 'appointment.service_name_snapshot',
    fieldTitle: 'Услуга',
    labelKey: 'SCHEDULING.REMINDERS.VARIABLES.SERVICE_NAME',
    defaultLabel: 'Услуга',
    example: 'Консультация',
    aliases: [
      'услуга',
      'сервис',
      'service_name',
      'appointment.service_name_snapshot',
    ],
  },
  {
    key: 'client_phone',
    token: '{{телефон клиента}}',
    fieldId: 'appointment.client_phone',
    fieldTitle: 'Телефон клиента',
    labelKey: 'SCHEDULING.REMINDERS.VARIABLES.CLIENT_PHONE',
    defaultLabel: 'Телефон клиента',
    example: '+7 701 000 00 00',
    aliases: [
      'телефон клиента',
      'телефон',
      'client_phone',
      'contact.phone_number',
      'appointment.client_phone',
    ],
  },
];

const normalizeTokenLabel = raw =>
  String(raw || '')
    .trim()
    .toLowerCase()
    .replace(/\s+/g, ' ');

export const findSemanticVariableByToken = rawToken => {
  const normalized = normalizeTokenLabel(rawToken);
  if (!normalized) return null;

  return (
    APPOINTMENT_SEMANTIC_VARIABLES.find(
      item =>
        item.key === normalized ||
        item.fieldId.toLowerCase() === normalized ||
        item.aliases.some(alias => alias.toLowerCase() === normalized)
    ) || null
  );
};

export const findSemanticVariableByFieldId = fieldId => {
  const normalized = String(fieldId || '').trim();
  return (
    APPOINTMENT_SEMANTIC_VARIABLES.find(item => item.fieldId === normalized) ||
    null
  );
};

export const buildFieldReferenceForSemanticKey = keyOrFieldId => {
  const variable =
    findSemanticVariableByToken(keyOrFieldId) ||
    findSemanticVariableByFieldId(keyOrFieldId);

  if (!variable) {
    return '';
  }

  return buildTemplateFieldReference({
    id: variable.fieldId,
    title: variable.fieldTitle,
  });
};

export const serializeSemanticTemplateText = (
  rawText,
  existingExamples = {}
) => {
  const source = String(rawText || '');
  const tokenMatches = [...source.matchAll(/{{\s*([^}]+?)\s*}}/g)];

  if (!tokenMatches.length) {
    return {
      serializedText: source,
      variables: [],
      examples: {},
      bindings: {},
      semanticMap: {},
      error: '',
    };
  }

  const allNumeric = tokenMatches.every(([, inner]) =>
    /^\d+$/.test(inner.trim())
  );

  if (allNumeric) {
    const numbers = [
      ...new Set(tokenMatches.map(([, inner]) => Number(inner.trim()))),
    ].sort((a, b) => a - b);
    const highest = numbers.at(-1);
    const expected = Array.from({ length: highest }, (_, index) => index + 1);
    if (
      numbers.length !== expected.length ||
      numbers.some((val, idx) => val !== expected[idx])
    ) {
      return {
        serializedText: source,
        variables: [],
        examples: {},
        bindings: {},
        semanticMap: {},
        error: 'Variables must be sequential without gaps',
      };
    }

    const variables = numbers.map(String);
    const examples = Object.fromEntries(
      variables.map(variable => [
        variable,
        String(existingExamples?.[variable] || '').trim(),
      ])
    );

    return {
      serializedText: source,
      variables,
      examples,
      bindings: {},
      semanticMap: {},
      error: '',
    };
  }

  const assignedIndexBySemanticKey = new Map();
  const examples = {};
  const bindings = {};
  const semanticMap = {};
  let nextIndex = 1;

  let unknownError = '';
  tokenMatches.forEach(([, inner]) => {
    if (unknownError) return;
    const trimmed = inner.trim();
    if (/^\d+$/.test(trimmed)) {
      const idxKey = String(Number(trimmed));
      if (!assignedIndexBySemanticKey.has(`__num_${idxKey}`)) {
        assignedIndexBySemanticKey.set(`__num_${idxKey}`, idxKey);
        examples[idxKey] = String(existingExamples?.[idxKey] || '').trim();
        nextIndex = Math.max(nextIndex, Number(idxKey) + 1);
      }
      return;
    }

    const matched = findSemanticVariableByToken(trimmed);
    if (!matched) {
      unknownError = `Unknown template variable: {{${trimmed}}}`;
      return;
    }

    if (!assignedIndexBySemanticKey.has(matched.key)) {
      const indexStr = String(nextIndex);
      nextIndex += 1;
      assignedIndexBySemanticKey.set(matched.key, indexStr);
      semanticMap[indexStr] = matched;
      examples[indexStr] =
        String(existingExamples?.[indexStr] || '').trim() || matched.example;
      bindings[indexStr] = buildFieldReferenceForSemanticKey(matched.key);
    }
  });

  if (unknownError) {
    return {
      serializedText: source,
      variables: [],
      examples: {},
      bindings: {},
      semanticMap: {},
      error: unknownError,
    };
  }

  const serializedText = source.replace(/{{\s*([^}]+?)\s*}}/g, (_, inner) => {
    const trimmed = inner.trim();
    if (/^\d+$/.test(trimmed)) {
      return `{{${Number(trimmed)}}}`;
    }
    const matched = findSemanticVariableByToken(trimmed);
    const indexStr = matched
      ? assignedIndexBySemanticKey.get(matched.key)
      : trimmed;
    return `{{${indexStr}}}`;
  });

  const variables = Object.keys(examples).sort((a, b) => Number(a) - Number(b));

  return {
    serializedText,
    variables,
    examples,
    bindings,
    semanticMap,
    error: '',
  };
};

export const validateUtilityTemplateDraft = ({
  name = 'booking_template',
  bodyText = '',
  language = 'ru',
  category = 'UTILITY',
  buttons = [],
  bilingual = false,
  maxBodyLength = 400,
  messages = {},
} = {}) => {
  const errors = [];
  const trimmedName = String(name || '').trim();
  const trimmedBody = String(bodyText || '').trim();
  const normalizedCategory = String(category || 'UTILITY')
    .trim()
    .toUpperCase();

  if (!trimmedName) {
    errors.push({
      code: 'name_required',
      message:
        messages.nameRequired || 'Укажите системное имя шаблона',
    });
  } else if (!/^[a-z0-9_]+$/.test(trimmedName)) {
    errors.push({
      code: 'name_format',
      message:
        messages.nameFormat ||
        'Имя шаблона может содержать только строчные латинские буквы, цифры и _',
    });
  }

  if (normalizedCategory !== 'UTILITY') {
    errors.push({
      code: 'invalid_category',
      message:
        'Категория шаблона для уведомлений о записи должна быть UTILITY',
    });
  }

  if (!trimmedBody) {
    errors.push({
      code: 'empty_body',
      message:
        messages.bodyRequired || 'Текст шаблона не может быть пустым',
    });
  } else if (trimmedBody.length > maxBodyLength) {
    errors.push({
      code: 'body_too_long',
      message: `Текст шаблона превышает лимит (${trimmedBody.length}/${maxBodyLength} символов)`,
    });
  }

  const serialized = serializeSemanticTemplateText(trimmedBody);
  if (serialized.error) {
    errors.push({
      code: 'invalid_variables',
      message: serialized.error,
    });
  }

  if (
    trimmedBody &&
    (/^\s*{{\s*[^}]+\s*}}/.test(trimmedBody) ||
      /{{\s*[^}]+\s*}}\s*$/.test(trimmedBody))
  ) {
    errors.push({
      code: 'dangling_variable',
      message:
        messages.danglingVariable ||
        'По правилам Meta текст не может начинаться или заканчиваться переменной — добавьте слово или знак препинания',
    });
  }

  if (/{{\s*[^}]+\s*}}\s*[,;:\-–—/\\|]*\s*{{\s*[^}]+\s*}}/.test(trimmedBody)) {
    errors.push({
      code: 'adjacent_variables',
      message:
        'Переменные не могут стоять вплотную друг к другу без слов между ними',
    });
  }

  if (/{{\s*[^}]+\s*}}\s*-\s*[а-яёәғқңөұүһіa-z]+/i.test(trimmedBody)) {
    errors.push({
      code: 'variable_case_suffix',
      message:
        'Нельзя приклеивать падежные окончания через дефис к переменным (например, {{3}}-ке). Перестройте фразу.',
    });
  }

  const lowerBody = trimmedBody.toLowerCase();
  const matchedStopWord = PROMOTIONAL_STOP_WORDS.find(word =>
    lowerBody.includes(word)
  );
  if (matchedStopWord) {
    errors.push({
      code: 'promotional_content',
      message: `Шаблон UTILITY не должен содержать рекламные слова («${matchedStopWord}»)`,
    });
  }

  const isBilingual = Boolean(bilingual || trimmedBody.includes('———'));
  if (!isBilingual && normalizeClientLanguageCode(language) === 'kk' && trimmedBody) {
    if (!/[әғқңөұүһіӘҒҚҢӨҰҮҺІ]/.test(trimmedBody)) {
      errors.push({
        code: 'language_mismatch_kk',
        message:
          'Шаблон на казахском языке (kk) должен содержать текст на казахском языке',
      });
    }
  }

  (Array.isArray(buttons) ? buttons : []).forEach(btn => {
    const btnText = String(btn?.text || '').trim();
    if (!btnText) {
      errors.push({
        code: 'empty_button_text',
        message:
          messages.buttonTextRequired || 'Укажите текст кнопки',
      });
    } else if (btnText.length > 20) {
      errors.push({
        code: 'button_text_too_long',
        message: `Текст кнопки «${btnText}» превышает 20 символов`,
      });
    }
  });

  return {
    valid: errors.length === 0,
    errors,
    errorMessages: errors.map(item => item.message),
    firstError: errors[0]?.message || '',
    serializedText: serialized.serializedText,
    variables: serialized.variables,
    examples: serialized.examples,
    bindings: serialized.bindings,
    semanticMap: serialized.semanticMap,
  };
};

export const APPOINTMENT_REMINDER_PRESETS = [
  {
    key: 'appointment_created',
    templateName: 'booking_created_notice',
    eventName: 'appointment_created',
    icon: 'i-lucide-calendar-check-2',
    timingMode: 'relative',
    relativeAnchor: 'touch.created_at',
    relativeOffsetSeconds: 60,
    relativeTimeMode: 'inherit_anchor_time',
    relativeTimeOfDay: '',
    supportsConfirmation: false,
    supportsDayBeforeTime: false,
    supportsReviewDelay: false,
    defaultVariableOrder: [
      'client_name',
      'appointment_date',
      'appointment_time',
      'specialist_name',
    ],
  },
  {
    key: 'appointment_rescheduled',
    templateName: 'booking_rescheduled_notice',
    eventName: 'appointment_rescheduled',
    icon: 'i-lucide-calendar-sync',
    timingMode: 'relative',
    relativeAnchor: 'touch.created_at',
    relativeOffsetSeconds: 60,
    relativeTimeMode: 'inherit_anchor_time',
    relativeTimeOfDay: '',
    supportsConfirmation: false,
    supportsDayBeforeTime: false,
    supportsReviewDelay: false,
    defaultVariableOrder: [
      'client_name',
      'appointment_date',
      'appointment_time',
      'specialist_name',
    ],
  },
  {
    key: 'appointment_cancelled',
    templateName: 'booking_cancelled_notice',
    eventName: 'appointment_cancelled',
    icon: 'i-lucide-calendar-x-2',
    timingMode: 'relative',
    relativeAnchor: 'touch.created_at',
    relativeOffsetSeconds: 60,
    relativeTimeMode: 'inherit_anchor_time',
    relativeTimeOfDay: '',
    supportsConfirmation: false,
    supportsDayBeforeTime: false,
    supportsReviewDelay: false,
    defaultVariableOrder: [
      'client_name',
      'appointment_date',
      'appointment_time',
      'specialist_name',
    ],
  },
  {
    key: 'appointment_day_before',
    templateName: 'booking_reminder_1d',
    eventName: 'appointment_created',
    icon: 'i-lucide-bell-ring',
    timingMode: 'relative',
    relativeAnchor: 'appointment.starts_at',
    relativeOffsetSeconds: -86400,
    relativeTimeMode: 'fixed_time_of_day',
    relativeTimeOfDay: '15:00',
    supportsConfirmation: true,
    supportsDayBeforeTime: true,
    supportsReviewDelay: false,
    defaultVariableOrder: [
      'client_name',
      'appointment_date',
      'appointment_time',
      'specialist_name',
    ],
  },
  {
    key: 'appointment_two_hours_before',
    templateName: 'booking_reminder_2h',
    eventName: 'appointment_created',
    icon: 'i-lucide-clock-alert',
    timingMode: 'relative',
    relativeAnchor: 'appointment.starts_at',
    relativeOffsetSeconds: -7200,
    relativeTimeMode: 'inherit_anchor_time',
    relativeTimeOfDay: '',
    supportsConfirmation: false,
    supportsDayBeforeTime: false,
    supportsReviewDelay: false,
    defaultVariableOrder: [
      'client_name',
      'appointment_time',
      'specialist_name',
    ],
  },
  {
    key: 'appointment_review_request',
    templateName: 'booking_feedback_request',
    eventName: 'appointment_completed',
    icon: 'i-lucide-message-square-heart',
    timingMode: 'relative',
    relativeAnchor: 'appointment.ends_at',
    relativeOffsetSeconds: 3600,
    relativeTimeMode: 'inherit_anchor_time',
    relativeTimeOfDay: '',
    supportsConfirmation: false,
    supportsDayBeforeTime: false,
    supportsReviewDelay: true,
    defaultVariableOrder: ['client_name', 'specialist_name'],
  },
];

const buildLanguageSection = (presetKey, lang, options) => {
  const isKk = lang === 'kk';
  const isEn = lang === 'en';
  const companyName = isKk
    ? String(options.companyNameKk || options.companyNameRu || '').trim()
    : String(options.companyNameRu || options.companyNameKk || '').trim();

  const greet = options.greetByName !== false;
  const includeCompany = Boolean(options.includeCompany && companyName);
  const includeDateTime = options.includeDateTime !== false;
  const includeSpecialist = options.includeSpecialist !== false;
  const includeService = options.includeService === true;

  const lines = [];

  if (isKk) {
    lines.push(greet ? 'Сәлеметсіз бе, {{имя клиента}}!' : 'Сәлеметсіз бе!');

    switch (presetKey) {
      case 'appointment_created':
        lines.push(
          includeCompany
            ? `Сіз «${companyName}» компаниясына жазылдыңыз.`
            : 'Сіздің жазылуыңыз тіркелді.'
        );
        break;
      case 'appointment_rescheduled':
        lines.push(
          includeCompany
            ? `«${companyName}» компаниясындағы жазылу уақытыңыз өзгертілді.`
            : 'Сіздің жазылу уақытыңыз өзгертілді.'
        );
        break;
      case 'appointment_cancelled':
        lines.push(
          includeCompany
            ? `«${companyName}» компаниясындағы жазылуыңыз тоқтатылды.`
            : 'Сіздің жазылуыңыз тоқтатылды.'
        );
        break;
      case 'appointment_day_before':
        lines.push(
          includeCompany
            ? `Еске саламыз: ертең «${companyName}» компаниясында жазылуыңыз бар.`
            : 'Еске саламыз: ертең сіздің жазылуыңыз бар.'
        );
        break;
      case 'appointment_two_hours_before':
        lines.push(
          includeCompany
            ? `Еске саламыз: 2 сағаттан кейін «${companyName}» компаниясында жазылуыңыз басталады.`
            : 'Еске саламыз: 2 сағаттан кейін сіздің жазылуыңыз басталады.'
        );
        break;
      case 'appointment_review_request':
        lines.push(
          includeCompany
            ? `«${companyName}» қызметін таңдағаныңызға рақмет!`
            : 'Бізге келгеніңізге рақмет!'
        );
        break;
      default:
        break;
    }

    if (presetKey !== 'appointment_review_request') {
      if (includeDateTime) {
        if (presetKey === 'appointment_two_hours_before') {
          lines.push('Уақыты: {{время записи}}.');
        } else {
          lines.push('Күні: {{дата записи}}, уақыты: {{время записи}}.');
        }
      }
      if (includeSpecialist) {
        lines.push('Маман: {{специалист}}.');
      }
      if (includeService && presetKey !== 'appointment_cancelled') {
        lines.push('Қызмет: {{услуга}}.');
      }
    } else {
      if (includeSpecialist) {
        lines.push('Маман: {{специалист}}.');
      }
      if (includeService) {
        lines.push('Қызмет: {{услуга}}.');
      }
    }

    if (presetKey === 'appointment_cancelled') {
      lines.push('Жаңа уақыт таңдау үшін осы хабарламаға жауап беріңіз.');
    } else if (presetKey === 'appointment_review_request') {
      lines.push('Сапаны жақсарту үшін өз пікіріңізді қалдыруды сұраймыз.');
    } else if (
      presetKey === 'appointment_day_before' &&
      options.confirmationDayBefore !== false
    ) {
      lines.push(
        'Келетініңізді төмендегі батырма арқылы растауыңызды сұраймыз.'
      );
    } else {
      lines.push('Белгіленген уақытта күтеміз.');
    }
  } else if (isEn) {
    lines.push(greet ? 'Hello, {{имя клиента}}!' : 'Hello!');
    const targetName = includeCompany ? companyName : 'our clinic';
    switch (presetKey) {
      case 'appointment_created':
        lines.push(`Your appointment at ${targetName} is confirmed.`);
        break;
      case 'appointment_rescheduled':
        lines.push(`Your appointment at ${targetName} has been rescheduled.`);
        break;
      case 'appointment_cancelled':
        lines.push(`Your appointment at ${targetName} has been cancelled.`);
        break;
      case 'appointment_day_before':
        lines.push(`Reminder: you have an appointment at ${targetName} tomorrow.`);
        break;
      case 'appointment_two_hours_before':
        lines.push(`Reminder: your appointment at ${targetName} starts in 2 hours.`);
        break;
      case 'appointment_review_request':
        lines.push(`Thank you for visiting ${targetName}!`);
        break;
      default:
        break;
    }
    if (presetKey !== 'appointment_review_request' && includeDateTime) {
      if (presetKey === 'appointment_two_hours_before') {
        lines.push('Time: {{время записи}}.');
      } else {
        lines.push('Date: {{дата записи}}, time: {{время записи}}.');
      }
    }
    if (includeSpecialist) lines.push('Specialist: {{специалист}}.');
    if (includeService && presetKey !== 'appointment_cancelled') {
      lines.push('Service: {{услуга}}.');
    }
    lines.push('We look forward to seeing you.');
  } else {
    lines.push(greet ? 'Здравствуйте, {{имя клиента}}!' : 'Здравствуйте!');

    switch (presetKey) {
      case 'appointment_created':
        lines.push(
          includeCompany
            ? `Вы записаны в «${companyName}».`
            : 'Ваша запись успешно создана.'
        );
        break;
      case 'appointment_rescheduled':
        lines.push(
          includeCompany
            ? `Ваша запись в «${companyName}» перенесена на новое время.`
            : 'Ваша запись перенесена на новое время.'
        );
        break;
      case 'appointment_cancelled':
        lines.push(
          includeCompany
            ? `Ваша запись в «${companyName}» отменена.`
            : 'Ваша запись отменена.'
        );
        break;
      case 'appointment_day_before':
        lines.push(
          includeCompany
            ? `Напоминаем: завтра у вас запись в «${companyName}».`
            : 'Напоминаем: завтра у вас запланирован визит.'
        );
        break;
      case 'appointment_two_hours_before':
        lines.push(
          includeCompany
            ? `Напоминаем: через 2 часа у вас запись в «${companyName}».`
            : 'Напоминаем: через 2 часа начинается ваш визит.'
        );
        break;
      case 'appointment_review_request':
        lines.push(
          includeCompany
            ? `Спасибо за визит в «${companyName}»!`
            : 'Спасибо за ваш визит!'
        );
        break;
      default:
        break;
    }

    if (presetKey !== 'appointment_review_request') {
      if (includeDateTime) {
        if (presetKey === 'appointment_two_hours_before') {
          lines.push('Время: {{время записи}}.');
        } else {
          lines.push('Дата: {{дата записи}}, время: {{время записи}}.');
        }
      }
      if (includeSpecialist) {
        lines.push('Специалист: {{специалист}}.');
      }
      if (includeService && presetKey !== 'appointment_cancelled') {
        lines.push('Услуга: {{услуга}}.');
      }
    } else {
      if (includeSpecialist) {
        lines.push('Специалист: {{специалист}}.');
      }
      if (includeService) {
        lines.push('Услуга: {{услуга}}.');
      }
    }

    if (presetKey === 'appointment_cancelled') {
      lines.push(
        'Если хотите выбрать другое время — ответьте на это сообщение.'
      );
    } else if (presetKey === 'appointment_review_request') {
      lines.push(
        'Будем благодарны за ваш отзыв — это помогает нам становиться лучше.'
      );
    } else if (
      presetKey === 'appointment_day_before' &&
      options.confirmationDayBefore !== false
    ) {
      lines.push('Пожалуйста, подтвердите визит кнопкой ниже.');
    } else {
      lines.push('Ждём вас в назначенное время.');
    }
  }

  return lines.join('\n');
};

export const buildAppointmentTemplatePackDrafts = (options = {}) => {
  const languageMode = options.languageMode || 'both';
  const metaLanguage =
    languageMode === 'both'
      ? 'ru'
      : normalizeClientLanguageCode(languageMode) || 'ru';
  const locationUrl = String(options.locationUrl || '').trim();
  const includeLocation = Boolean(options.includeLocationUrl && locationUrl);

  return APPOINTMENT_REMINDER_PRESETS.map(preset => {
    const bodyText =
      languageMode === 'both'
        ? `${buildLanguageSection(preset.key, 'kk', options)}\n\n—————————\n\n${buildLanguageSection(preset.key, 'ru', options)}`
        : buildLanguageSection(preset.key, metaLanguage, options);

    const buttons = [];

    if (
      preset.key === 'appointment_day_before' &&
      options.confirmationDayBefore !== false
    ) {
      buttons.push({
        type: 'QUICK_REPLY',
        text:
          languageMode === 'kk'
            ? 'Жазылуды растаймын'
            : languageMode === 'en'
              ? 'Confirm visit'
              : 'Подтверждаю запись',
        url: '',
        example: '',
        phoneNumber: '',
      });
    } else if (
      includeLocation &&
      [
        'appointment_created',
        'appointment_rescheduled',
        'appointment_day_before',
        'appointment_two_hours_before',
      ].includes(preset.key)
    ) {
      buttons.push({
        type: 'URL',
        text:
          languageMode === 'kk'
            ? 'Картадан ашу'
            : languageMode === 'en'
              ? 'Directions'
              : 'Как добраться',
        url: locationUrl,
        example: '',
        phoneNumber: '',
      });
    }

    const serialized = serializeSemanticTemplateText(bodyText);

    return {
      presetKey: preset.key,
      name: preset.templateName,
      language: metaLanguage,
      category: 'UTILITY',
      headerType: 'none',
      headerText: '',
      bodyText,
      serializedBodyText: serialized.serializedText,
      footerText: '',
      sampleMediaUrl: '',
      sampleMediaBlobId: '',
      bodyExamples: serialized.examples,
      headerExamples: {},
      variableBindings: serialized.bindings,
      semanticKeyMap: Object.fromEntries(
        Object.entries(serialized.semanticMap || {}).map(([idx, item]) => [
          idx,
          item.key,
        ])
      ),
      buttons,
    };
  });
};
