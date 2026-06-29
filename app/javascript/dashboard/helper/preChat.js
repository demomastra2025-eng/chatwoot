import i18n from 'widget/i18n/index';
const defaultTranslations = Object.fromEntries(
  Object.entries(i18n).filter(([key]) => key.includes('ru'))
).ru;

export const standardFieldKeys = {
  emailAddress: {
    key: 'EMAIL_ADDRESS',
    label: 'Email Id',
    placeholder: 'Please enter your email address',
  },
  fullName: {
    key: 'FULL_NAME',
    label: 'Full Name',
    placeholder: 'Please enter your full name',
  },
  phoneNumber: {
    key: 'PHONE_NUMBER',
    label: 'Phone Number',
    placeholder: 'Please enter your phone number',
  },
};

const phoneFieldNames = ['phoneNumber', 'phone_number', 'phone', 'mobile'];

export const isPhoneField = field => phoneFieldNames.includes(field?.name);

export const getLabel = ({ key, label }) => {
  return defaultTranslations.PRE_CHAT_FORM.FIELDS[key]
    ? defaultTranslations.PRE_CHAT_FORM.FIELDS[key].LABEL
    : label;
};
export const getPlaceHolder = ({ key, placeholder }) => {
  return defaultTranslations.PRE_CHAT_FORM.FIELDS[key]
    ? defaultTranslations.PRE_CHAT_FORM.FIELDS[key].PLACEHOLDER
    : placeholder;
};

const withRequiredPhoneField = fields => {
  const formattedFields = fields.map(field => {
    if (!isPhoneField(field)) return field;

    return {
      ...field,
      type: field.type === 'text' ? 'tel' : field.type || 'tel',
      required: true,
      enabled: true,
    };
  });

  if (formattedFields.some(isPhoneField)) return formattedFields;

  return [
    {
      label: getLabel({
        key: standardFieldKeys.phoneNumber.key,
        label: standardFieldKeys.phoneNumber.label,
      }),
      name: 'phoneNumber',
      placeholder: getPlaceHolder({
        key: standardFieldKeys.phoneNumber.key,
        placeholder: standardFieldKeys.phoneNumber.placeholder,
      }),
      type: 'tel',
      field_type: 'standard',
      required: true,
      enabled: true,
    },
    ...formattedFields,
  ];
};

export const getCustomFields = ({ standardFields, customAttributes }) => {
  let customFields = [];
  const { pre_chat_fields: preChatFields } = standardFields;
  customAttributes.forEach(attribute => {
    const itemExist = preChatFields.find(
      item => item.name === attribute.attribute_key
    );
    if (!itemExist) {
      customFields.push({
        label: attribute.attribute_display_name,
        placeholder: attribute.attribute_display_name,
        name: attribute.attribute_key,
        type: attribute.attribute_display_type,
        values: attribute.attribute_values,
        field_type: attribute.attribute_model,
        regex_pattern: attribute.regex_pattern,
        regex_cue: attribute.regex_cue,
        required: false,
        enabled: false,
      });
    }
  });
  return customFields;
};

export const getFormattedPreChatFields = ({ preChatFields }) => {
  const formattedFields = preChatFields.map(item => {
    return {
      ...item,
      label: getLabel({
        key: item.name,
        label: item.label ? item.label : item.name,
      }),
      placeholder: getPlaceHolder({
        key: item.name,
        placeholder: item.placeholder ? item.placeholder : item.name,
      }),
    };
  });

  return withRequiredPhoneField(formattedFields);
};

export const getPreChatFields = ({
  preChatFormOptions = {},
  customAttributes = [],
}) => {
  const { pre_chat_message, pre_chat_fields = [] } = preChatFormOptions;
  let customFields = {};
  let preChatFields = {};

  const formattedPreChatFields = getFormattedPreChatFields({
    preChatFields: pre_chat_fields,
  });

  customFields = getCustomFields({
    standardFields: { pre_chat_fields: formattedPreChatFields },
    customAttributes,
  });
  preChatFields = [...formattedPreChatFields, ...customFields];

  return {
    pre_chat_message,
    pre_chat_fields: preChatFields,
  };
};
