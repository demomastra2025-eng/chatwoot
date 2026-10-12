export const appointmentCrmLinkWarningMessage = (appointment, t) => {
  const result = appointment?.crmLinkResult || appointment?.crm_link_result;
  if (result?.status !== 'not_linked') return '';

  const key =
    result.code === 'DEAL_STAGE_REQUIRES_FIELDS'
      ? 'SCHEDULING.APPOINTMENT_FORM.SAVED_WITHOUT_DEAL_REQUIRED_FIELDS'
      : 'SCHEDULING.APPOINTMENT_FORM.SAVED_WITHOUT_DEAL';
  return t(key);
};

// A MedElement reschedule is a request: the appointment keeps its confirmed time until MedElement confirms the move.
export const appointmentProviderMoveMessage = (appointment, t) => {
  const state =
    appointment?.providerMove?.state || appointment?.provider_move?.state;
  return state === 'pending'
    ? t('SCHEDULING.APPOINTMENT_FORM.MOVE_PENDING')
    : '';
};

export const appointmentSaveAlertMessage = (appointment, t) =>
  appointmentCrmLinkWarningMessage(appointment, t) ||
  appointmentProviderMoveMessage(appointment, t) ||
  t('SCHEDULING.APPOINTMENT_FORM.SUCCESS_SAVE');
