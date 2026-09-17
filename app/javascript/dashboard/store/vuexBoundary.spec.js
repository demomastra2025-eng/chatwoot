import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const currentDir = dirname(fileURLToPath(import.meta.url));
const storeSource = () => readFileSync(resolve(currentDir, 'index.js'), 'utf8');

const legacyVuexModuleImports = new Set([
  './captain/assistant',
  './captain/bulkActions',
  './captain/customTools',
  './captain/document',
  './captain/inboxes',
  './captain/mcpServers',
  './captain/response',
  './captain/scenarios',
  './captain/tools',
  './modules/SLAReports',
  './modules/accounts',
  './modules/agentCapacityPolicies',
  './modules/agents',
  './modules/assignmentPolicies',
  './modules/attributes',
  './modules/auditlogs',
  './modules/auth',
  './modules/automations',
  './modules/bulkActions',
  './modules/campaigns',
  './modules/cannedResponse',
  './modules/contactConversations',
  './modules/contactLabels',
  './modules/contactNotes',
  './modules/contacts',
  './modules/conversationLabels',
  './modules/conversationMetadata',
  './modules/conversationSearch',
  './modules/conversationStats',
  './modules/conversationTypingStatus',
  './modules/conversationWatchers',
  './modules/conversations',
  './modules/csat',
  './modules/customRole',
  './modules/customViews',
  './modules/dashboardApps',
  './modules/draftMessages',
  './modules/helpCenterArticles',
  './modules/helpCenterCategories',
  './modules/helpCenterPortals',
  './modules/inboxAssignableAgents',
  './modules/inboxMembers',
  './modules/inboxes',
  './modules/integrations',
  './modules/labels',
  './modules/macros',
  './modules/notifications',
  './modules/reports',
  './modules/sla',
  './modules/summaryReports',
  './modules/teamMembers',
  './modules/teams',
  './modules/userNotificationSettings',
  './modules/webhooks',
]);

const registeredLegacyImports = source =>
  [
    ...source.matchAll(
      /['"]((?:\.\/|dashboard\/store\/)(?:modules|captain)\/[^'"]+)['"]/g
    ),
  ].map(match => match[1].replace('dashboard/store/', './'));

describe('dashboard state boundary', () => {
  it('rejects new Vuex modules while allowing legacy modules to be removed', () => {
    const unexpectedModules = registeredLegacyImports(storeSource()).filter(
      modulePath => !legacyVuexModuleImports.has(modulePath)
    );

    expect(unexpectedModules).toEqual([]);
  });

  it('detects multiline, named, namespace, and aliased module imports', () => {
    const source = `
      import {
        futureModule
      } from './modules/future';
      import * as captainModule from "dashboard/store/captain/future";
    `;

    expect(registeredLegacyImports(source)).toEqual([
      './modules/future',
      './captain/future',
    ]);
  });

  it('keeps conversation pagination out of the legacy Vuex registry', () => {
    expect(storeSource()).not.toContain('conversationPage');
  });
});
