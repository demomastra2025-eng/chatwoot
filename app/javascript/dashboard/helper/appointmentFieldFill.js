import axios from 'axios';

export const appointmentFieldIds = references => [
  ...new Set(
    references.flatMap(value =>
      [...String(value || '').matchAll(/field:\/\/(appointment\.[^)]+)/g)].map(
        match => match[1]
      )
    )
  ),
];

export const blockingFieldStats = (stats, fieldIds) =>
  (stats || []).filter(
    stat => fieldIds.includes(stat.field_id) && stat.blocking
  );

export const fetchAppointmentFieldFill = async (accountId, fieldIds) => {
  if (!fieldIds.length) return [];

  const response = await axios.get(
    `/api/v1/accounts/${accountId}/scheduling/appointment_field_fill`,
    { params: { field_ids: fieldIds } }
  );
  return response.data;
};
