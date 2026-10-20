import { splitName } from '@chatwoot/utils';

const cleanName = value =>
  String(value || '')
    .trim()
    .replace(/\s+/g, ' ');

const stripTrailingNameTokens = (value, suffixes) => {
  let tokens = cleanName(value).split(' ').filter(Boolean);
  suffixes.forEach(suffix => {
    const suffixTokens = cleanName(suffix).split(' ').filter(Boolean);
    if (!suffixTokens.length || tokens.length <= suffixTokens.length) return;
    const tail = tokens
      .slice(-suffixTokens.length)
      .map(token => token.toLowerCase());
    const target = suffixTokens.map(token => token.toLowerCase());
    if (tail.every((token, index) => token === target[index])) {
      tokens = tokens.slice(0, -suffixTokens.length);
    }
  });
  return tokens.join(' ');
};

export const schedulingContactNameParts = contact => {
  const rawFirstName = cleanName(contact?.firstName || contact?.first_name);
  const lastName = cleanName(contact?.lastName || contact?.last_name);
  const middleName = cleanName(contact?.middleName || contact?.middle_name);
  const fullName = cleanName(
    contact?.fullName || contact?.full_name || contact?.name || rawFirstName
  );

  if (lastName || middleName) {
    const firstName = stripTrailingNameTokens(rawFirstName || fullName, [
      middleName,
      lastName,
    ]);
    return {
      firstName: firstName || rawFirstName,
      lastName,
      middleName,
    };
  }

  if (fullName.split(' ').length !== 2) {
    return { firstName: rawFirstName || fullName, lastName: '', middleName };
  }

  const parsedName = splitName(fullName);
  return {
    firstName: cleanName(parsedName.firstName),
    lastName: cleanName(parsedName.lastName),
    middleName,
  };
};
