import { frontendURL } from '../../../../helper/URLHelper';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';

const ReportsWrapper = () => import('./components/ReportsWrapper.vue');
const Index = () => import('./Index.vue');
const AgentReportsIndex = () => import('./AgentReportsIndex.vue');
const InboxReportsIndex = () => import('./InboxReportsIndex.vue');
const TeamReportsIndex = () => import('./TeamReportsIndex.vue');
const LabelReportsIndex = () => import('./LabelReportsIndex.vue');
const AgentReportsShow = () => import('./AgentReportsShow.vue');
const InboxReportsShow = () => import('./InboxReportsShow.vue');
const TeamReportsShow = () => import('./TeamReportsShow.vue');
const LabelReportsShow = () => import('./LabelReportsShow.vue');
const AgentReports = () => import('./AgentReports.vue');
const InboxReports = () => import('./InboxReports.vue');
const LabelReports = () => import('./LabelReports.vue');
const TeamReports = () => import('./TeamReports.vue');
const CsatResponses = () => import('./CsatResponses.vue');
const BotReports = () => import('./BotReports.vue');
const DealReports = () => import('./DealReports.vue');
const LiveReports = () => import('./LiveReports.vue');
const SLAReports = () => import('./SLAReports.vue');
const meta = {
  featureFlag: FEATURE_FLAGS.REPORTS,
  permissions: ['administrator', 'report_manage'],
};

const oldReportRoutes = [
  {
    path: 'agent',
    name: 'agent_reports',
    meta,
    component: AgentReports,
  },
  {
    path: 'inboxes',
    name: 'inbox_reports',
    meta,
    component: InboxReports,
  },
  {
    path: 'label',
    name: 'label_reports',
    meta,
    component: LabelReports,
  },
  {
    path: 'teams',
    name: 'team_reports',
    meta,
    component: TeamReports,
  },
];

const revisedReportRoutes = [
  {
    path: 'agents_overview',
    name: 'agent_reports_index',
    meta: {
      permissions: ['administrator', 'report_manage'],
    },
    component: AgentReportsIndex,
  },
  {
    path: 'agents/:id',
    name: 'agent_reports_show',
    meta: {
      permissions: ['administrator', 'report_manage'],
    },
    component: AgentReportsShow,
  },

  {
    path: 'inboxes_overview',
    name: 'inbox_reports_index',
    meta: {
      permissions: ['administrator', 'report_manage'],
    },
    component: InboxReportsIndex,
  },
  {
    path: 'inboxes/:id',
    name: 'inbox_reports_show',
    meta: {
      permissions: ['administrator', 'report_manage'],
    },
    component: InboxReportsShow,
  },
  {
    path: 'teams_overview',
    name: 'team_reports_index',
    meta: {
      permissions: ['administrator', 'report_manage'],
    },
    component: TeamReportsIndex,
  },
  {
    path: 'teams/:id',
    name: 'team_reports_show',
    meta: {
      permissions: ['administrator', 'report_manage'],
    },
    component: TeamReportsShow,
  },
  {
    path: 'labels_overview',
    name: 'label_reports_index',
    meta: {
      permissions: ['administrator', 'report_manage'],
    },
    component: LabelReportsIndex,
  },
  {
    path: 'labels/:id',
    name: 'label_reports_show',
    meta: {
      permissions: ['administrator', 'report_manage'],
    },
    component: LabelReportsShow,
  },
];

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/reports'),
      component: ReportsWrapper,
      children: [
        {
          path: '',
          redirect: to => {
            return { name: 'account_overview_reports', params: to.params };
          },
        },
        {
          path: 'overview',
          name: 'account_overview_reports',
          meta,
          component: LiveReports,
        },
        {
          path: 'conversation',
          name: 'conversation_reports',
          meta,
          component: Index,
        },
        {
          path: 'funnels',
          name: 'funnel_reports',
          redirect: to => ({
            name: 'deal_reports',
            params: to.params,
            query: to.query,
          }),
        },
        {
          path: 'deals',
          name: 'deal_reports',
          meta,
          component: DealReports,
        },
        ...oldReportRoutes,
        ...revisedReportRoutes,
        {
          path: 'sla',
          name: 'sla_reports',
          meta,
          component: SLAReports,
        },
        {
          path: 'csat',
          name: 'csat_reports',
          meta,
          component: CsatResponses,
        },
        {
          path: 'bot',
          name: 'bot_reports',
          meta,
          component: BotReports,
        },
      ],
    },
  ],
};
