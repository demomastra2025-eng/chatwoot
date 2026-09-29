import { describe, expect, it } from 'vitest';

import {
  hasExclusiveConversationScope,
  resolveConversationAssigneeType,
  resolveRouteConversationAssigneeType,
  selectExclusiveSidebarChildNames,
} from './sidebarActiveSelection';

describe('resolveRouteConversationAssigneeType', () => {
  it('uses All for a clean conversation detail URL', () => {
    expect(resolveRouteConversationAssigneeType({})).toBe('all');
  });

  it('preserves explicit snake-case and camel-case scopes', () => {
    expect(
      resolveRouteConversationAssigneeType({ assignee_type: 'unassigned' })
    ).toBe('unassigned');
    expect(resolveRouteConversationAssigneeType({ assigneeType: 'me' })).toBe(
      'me'
    );
  });
});

describe('selectExclusiveSidebarChildNames', () => {
  it('keeps only a selected funnel stage when the all tab also matches', () => {
    expect(
      selectExclusiveSidebarChildNames(['Assignee:all', 'PipelineStage:10:20'])
    ).toEqual(['PipelineStage:10:20']);
  });

  it('keeps only a tag when the all or mine tab also matches', () => {
    expect(
      selectExclusiveSidebarChildNames(['Assignee:me', 'Important-42'])
    ).toEqual(['Important-42']);
  });

  it('keeps at most one assignee tab active', () => {
    expect(
      selectExclusiveSidebarChildNames(['Assignee:all', 'Assignee:me'])
    ).toEqual(['Assignee:all']);
  });

  it('forces tag and funnel-stage scopes to use all assignees', () => {
    const allowedTypes = ['all', 'me', 'unassigned'];
    const tagScope = hasExclusiveConversationScope({ label: 'important' });
    const stageScope = hasExclusiveConversationScope({
      query: { crm_stage_id: '20' },
    });

    expect(
      resolveConversationAssigneeType({
        requestedType: 'me',
        allowedTypes,
        allType: 'all',
        hasExclusiveScope: tagScope,
      })
    ).toBe('all');
    expect(
      resolveConversationAssigneeType({
        requestedType: 'me',
        allowedTypes,
        allType: 'all',
        hasExclusiveScope: stageScope,
      })
    ).toBe('all');
  });
});
