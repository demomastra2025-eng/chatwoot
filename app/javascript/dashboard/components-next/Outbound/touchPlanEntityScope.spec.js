import { describe, expect, it } from 'vitest';
import {
  buildTouchPlanStepEntityScope,
  touchPlanStepEntityKindPayload,
  touchPlanStepEntityKinds,
} from './touchPlanEntityScope';

describe('touchPlanEntityScope', () => {
  it('preserves a persisted legacy step as shared across the original plan scope', () => {
    const scope = buildTouchPlanStepEntityScope({
      seed: { step_id: 'legacy-step', relative_anchor: 'touch.created_at' },
      inferredEntityKind: 'appointment',
      planEntityKinds: ['appointment', 'deal'],
    });

    expect(scope).toEqual({
      entityKind: 'appointment',
      legacySharedEntityKinds: ['appointment', 'deal'],
    });
    expect(touchPlanStepEntityKinds(scope)).toEqual(['appointment', 'deal']);
    expect(touchPlanStepEntityKindPayload(scope)).toEqual({});
  });

  it('serializes an explicit step with its entity kind', () => {
    const scope = buildTouchPlanStepEntityScope({
      seed: { step_id: 'deal-step', entity_kind: 'deal' },
      inferredEntityKind: 'appointment',
      planEntityKinds: ['appointment', 'deal'],
    });

    expect(touchPlanStepEntityKinds(scope)).toEqual(['deal']);
    expect(touchPlanStepEntityKindPayload(scope)).toEqual({
      entity_kind: 'deal',
    });
  });
});
