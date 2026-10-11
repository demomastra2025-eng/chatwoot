export const appointmentCrmLinkWarningMessage = (appointment, t) => {
  const result = appointment?.crmLinkResult || appointment?.crm_link_result;
  if (result?.status !== 'not_linked') return '';

  const key =
    result.code === 'DEAL_STAGE_REQUIRES_FIELDS'
      ? 'SCHEDULING.APPOINTMENT_FORM.SAVED_WITHOUT_DEAL_REQUIRED_FIELDS'
      : 'SCHEDULING.APPOINTMENT_FORM.SAVED_WITHOUT_DEAL';
  return t(key);
};

export const appointmentSaveAlertMessage = (appointment, t) =>
  appointmentCrmLinkWarningMessage(appointment, t) ||
  t('SCHEDULING.APPOINTMENT_FORM.SUCCESS_SAVE');
