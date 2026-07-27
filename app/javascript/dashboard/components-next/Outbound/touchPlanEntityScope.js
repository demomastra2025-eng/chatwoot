const normalizeEntityKinds = entityKinds => {
  const kinds = Array.isArray(entityKinds) ? entityKinds : [entityKinds];
  return Array.from(new Set(kinds.filter(Boolean)));
};

export const buildTouchPlanStepEntityScope = ({
  seed = {},
  inferredEntityKind,
  planEntityKinds = [],
}) => {
  const explicitEntityKind = seed.entity_kind || seed.entityKind;
  const isPersistedLegacyStep = Boolean(seed.step_id) && !explicitEntityKind;

  return {
    entityKind: explicitEntityKind || inferredEntityKind,
    legacySharedEntityKinds: isPersistedLegacyStep
      ? normalizeEntityKinds(planEntityKinds)
      : [],
  };
};

export const touchPlanStepEntityKinds = step => {
  const legacySharedEntityKinds = normalizeEntityKinds(
    step.legacySharedEntityKinds
  );

  if (legacySharedEntityKinds.length) {
    return legacySharedEntityKinds;
  }

  return step.entityKind ? [step.entityKind] : [];
};

export const touchPlanStepEntityKindPayload = step => {
  if (normalizeEntityKinds(step.legacySharedEntityKinds).length) {
    return {};
  }

  return { entity_kind: step.entityKind };
};
