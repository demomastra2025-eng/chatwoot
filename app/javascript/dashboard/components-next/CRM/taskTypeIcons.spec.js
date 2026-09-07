import { describe, expect, it } from 'vitest';

import { CRM_TASK_TYPE_ICONS, normalizeCrmTaskTypeIcon } from './taskTypeIcons';

describe('task type icons', () => {
  it('keeps supported icons', () => {
    expect(normalizeCrmTaskTypeIcon('i-lucide-phone')).toBe('i-lucide-phone');
  });

  it('keeps valid API-created icons and rejects malformed values', () => {
    expect(normalizeCrmTaskTypeIcon('i-lucide-building-2')).toBe(
      'i-lucide-building-2'
    );
    expect(normalizeCrmTaskTypeIcon('')).toBe(CRM_TASK_TYPE_ICONS[0]);
    expect(normalizeCrmTaskTypeIcon('text-red-500')).toBe(
      CRM_TASK_TYPE_ICONS[0]
    );
  });
});
