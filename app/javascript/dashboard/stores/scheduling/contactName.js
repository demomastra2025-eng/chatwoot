import { splitName } from '@chatwoot/utils';

const cleanName = value =>
  String(value || '')
    .trim()
    .replace(/\s+/g, ' ');

export const schedulingContactNameParts = contact => {
  const firstName = cleanName(contact?.firstName || contact?.first_name);
  const lastName = cleanName(contact?.lastName || contact?.last_name);
  const middleName = cleanName(contact?.middleName || contact?.middle_name);

  if (lastName) return { firstName, lastName, middleName };

  const fullName = cleanName(
    contact?.fullName || contact?.full_name || firstName
  );
  if (fullName.split(' ').length !== 2) {
    return { firstName: firstName || fullName, lastName: '', middleName };
  }

  const parsedName = splitName(fullName);
  return {
    firstName: cleanName(parsedName.firstName),
    lastName: cleanName(parsedName.lastName),
    middleName,
  };
};
