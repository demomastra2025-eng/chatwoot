export const UNSORTED_STAGE_CODE = 'new';

export const defaultStageForManualDeal = pipeline => {
  const stages = pipeline?.stages || [];

  return (
    stages.find(stage => stage.default && stage.active) ||
    stages.find(stage => stage.active && stage.outcome === 'open')
  );
};

export const dealStageDisplayName = (stage, t) =>
  stage?.code === UNSORTED_STAGE_CODE
    ? t('CRM.SETTINGS.STAGES.SYSTEM.UNSORTED')
    : stage?.name;
