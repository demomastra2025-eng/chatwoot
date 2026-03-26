<script setup>
import { computed, nextTick, onMounted, reactive, ref, watch } from 'vue';
import { onBeforeRouteLeave, useRoute, useRouter } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useEventListener } from '@vueuse/core';
import Drawflow from 'drawflow';
import 'drawflow/dist/drawflow.min.css';

import { useAlert } from 'dashboard/composables';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import {
  buildNodeRecord,
  cloneFlowConfig,
  countConnections,
  createDefaultFlowConfig,
  FLOW_CONDITION_FIELD_OPTIONS,
  FLOW_CONDITION_OPERATOR_OPTIONS,
  FLOW_NODE_DEFINITIONS,
  FLOW_TRIGGER_OPTIONS,
  getFlowData,
  getOutputCount,
  getTriggerSummary,
} from './flowBuilder/defaultConfig';

const store = useStore();
const route = useRoute();
const router = useRouter();
const { t } = useI18n();

const labels = useMapGetter('labels/getLabels');
const teams = useMapGetter('teams/getTeams');
const agents = useMapGetter('agents/getAgents');
const uiFlags = useMapGetter('agentBots/getUIFlags');

const editorCanvasRef = ref(null);
const canvasShellRef = ref(null);
const fileInputRef = ref(null);
const editor = ref(null);
const isBooting = ref(true);
const isSaving = ref(false);
const isDirty = ref(false);
const selectedNodeId = ref('');
const draggedNodeType = ref('');
const armedNodeType = ref('');
const zoomLevel = ref(1);
const initializedBotId = ref(null);

const botMeta = reactive({
  name: '',
  description: '',
});

const flowConfig = ref(createDefaultFlowConfig());

const bot = computed(() =>
  store.getters['agentBots/getBot'](route.params.botId)
);

const flowNodes = computed(() => getFlowData(flowConfig.value));
const nodeList = computed(() => Object.values(flowNodes.value));
const triggerNodes = computed(() =>
  nodeList.value.filter(node => node.name === 'trigger')
);
const triggerNode = computed(() => triggerNodes.value[0] || null);
const selectedNode = computed(
  () => flowNodes.value[selectedNodeId.value] || null
);
const inspectorNode = computed(() => selectedNode.value || triggerNode.value);
const connectionCount = computed(() => countConnections(flowConfig.value));
const nodeCount = computed(() => nodeList.value.length);
const showCanvasEmpty = computed(
  () => nodeCount.value === 1 && connectionCount.value === 0
);
const isLoading = computed(
  () => isBooting.value || uiFlags.value.isFetchingItem
);
const isFlowBot = computed(
  () => Boolean(bot.value?.id) && bot.value.bot_type === 'flow_builder'
);
const canDeleteSelectedNode = computed(() => {
  if (!selectedNode.value) return false;
  if (selectedNode.value.name !== 'trigger') return true;

  return triggerNodes.value.length > 1;
});

const labelsById = computed(() =>
  Object.fromEntries(
    labels.value.map(label => [String(label.id), label.title || label.name])
  )
);

const teamsById = computed(() =>
  Object.fromEntries(teams.value.map(team => [String(team.id), team.name]))
);

const agentsById = computed(() =>
  Object.fromEntries(
    agents.value.map(agent => [
      String(agent.id),
      agent.name || agent.available_name || agent.email,
    ])
  )
);

const translateTriggerOption = value => {
  switch (value) {
    case 'first_message':
      return t('AGENT_BOTS.BUILDER.TRIGGERS.FIRST_MESSAGE');
    case 'keyword':
      return t('AGENT_BOTS.BUILDER.TRIGGERS.KEYWORD');
    case 'all_messages':
    default:
      return t('AGENT_BOTS.BUILDER.TRIGGERS.ALL_MESSAGES');
  }
};

const translateConditionFieldOption = value => {
  switch (value) {
    case 'conversation_status':
      return t('AGENT_BOTS.BUILDER.CONDITION_FIELDS.CONVERSATION_STATUS');
    case 'has_label':
      return t('AGENT_BOTS.BUILDER.CONDITION_FIELDS.HAS_LABEL');
    case 'message_text':
    default:
      return t('AGENT_BOTS.BUILDER.CONDITION_FIELDS.MESSAGE_TEXT');
  }
};

const translateConditionOperatorOption = value => {
  switch (value) {
    case 'equals':
      return t('AGENT_BOTS.BUILDER.CONDITION_OPERATORS.EQUALS');
    case 'contains':
    default:
      return t('AGENT_BOTS.BUILDER.CONDITION_OPERATORS.CONTAINS');
  }
};

const translateNodeTitle = type => {
  switch (type) {
    case 'trigger':
      return t('AGENT_BOTS.BUILDER.NODES.TRIGGER.TITLE');
    case 'message':
      return t('AGENT_BOTS.BUILDER.STEPS.MESSAGE');
    case 'menu':
      return t('AGENT_BOTS.BUILDER.STEPS.MENU');
    case 'condition':
      return t('AGENT_BOTS.BUILDER.NODES.CONDITION.TITLE');
    case 'delay':
      return t('AGENT_BOTS.BUILDER.NODES.DELAY.TITLE');
    case 'note':
      return t('AGENT_BOTS.BUILDER.NODES.NOTE.TITLE');
    case 'add_label':
      return t('AGENT_BOTS.BUILDER.STEPS.ADD_LABEL');
    case 'remove_label':
      return t('AGENT_BOTS.BUILDER.STEPS.REMOVE_LABEL');
    case 'assign_team':
      return t('AGENT_BOTS.BUILDER.STEPS.ASSIGN_TEAM');
    case 'assign_agent':
      return t('AGENT_BOTS.BUILDER.STEPS.ASSIGN_AGENT');
    case 'change_status':
      return t('AGENT_BOTS.BUILDER.STEPS.CHANGE_STATUS');
    case 'handoff':
      return t('AGENT_BOTS.BUILDER.STEPS.HANDOFF');
    case 'webhook':
      return t('AGENT_BOTS.TYPES.WEBHOOK');
    default:
      return type;
  }
};

const translateNodeDescription = type => {
  switch (type) {
    case 'trigger':
      return t('AGENT_BOTS.BUILDER.NODES.TRIGGER.DESCRIPTION');
    case 'message':
      return t('AGENT_BOTS.BUILDER.STEP_HELP.MESSAGE');
    case 'menu':
      return t('AGENT_BOTS.BUILDER.STEP_HELP.MENU');
    case 'condition':
      return t('AGENT_BOTS.BUILDER.NODES.CONDITION.DESCRIPTION');
    case 'delay':
      return t('AGENT_BOTS.BUILDER.NODES.DELAY.DESCRIPTION');
    case 'note':
      return t('AGENT_BOTS.BUILDER.NODES.NOTE.DESCRIPTION');
    case 'add_label':
      return t('AGENT_BOTS.BUILDER.STEP_HELP.ADD_LABEL');
    case 'remove_label':
      return t('AGENT_BOTS.BUILDER.STEP_HELP.REMOVE_LABEL');
    case 'assign_team':
      return t('AGENT_BOTS.BUILDER.STEP_HELP.ASSIGN_TEAM');
    case 'assign_agent':
      return t('AGENT_BOTS.BUILDER.STEP_HELP.ASSIGN_AGENT');
    case 'change_status':
      return t('AGENT_BOTS.BUILDER.STEP_HELP.CHANGE_STATUS');
    case 'handoff':
      return t('AGENT_BOTS.BUILDER.STEP_HELP.HANDOFF');
    case 'webhook':
      return t('AGENT_BOTS.WEBHOOK.DESCRIPTION');
    default:
      return t('AGENT_BOTS.BUILDER.NODE_SUMMARY.NOT_SET');
  }
};

const paletteGroups = computed(() => {
  const groups = [
    { key: 'triggers', label: t('AGENT_BOTS.BUILDER.GROUPS.TRIGGERS') },
    { key: 'messages', label: t('AGENT_BOTS.BUILDER.GROUPS.MESSAGES') },
    { key: 'logic', label: t('AGENT_BOTS.BUILDER.GROUPS.LOGIC') },
    { key: 'routing', label: t('AGENT_BOTS.BUILDER.GROUPS.ROUTING') },
    { key: 'actions', label: t('AGENT_BOTS.BUILDER.GROUPS.ACTIONS') },
    {
      key: 'integrations',
      label: t('AGENT_BOTS.BUILDER.GROUPS.INTEGRATIONS'),
    },
  ];

  return groups
    .map(group => ({
      ...group,
      items: Object.entries(FLOW_NODE_DEFINITIONS)
        .filter(([, definition]) => definition.group === group.key)
        .map(([type, definition]) => ({
          type,
          icon: definition.icon,
          tint: definition.tint,
          title: translateNodeTitle(type),
          description: translateNodeDescription(type),
        })),
    }))
    .filter(group => group.items.length);
});

const statusOptions = computed(() => [
  { value: 'open', label: t('AGENT_BOTS.BUILDER.STATUS.OPEN') },
  { value: 'pending', label: t('AGENT_BOTS.BUILDER.STATUS.PENDING') },
  { value: 'resolved', label: t('AGENT_BOTS.BUILDER.STATUS.RESOLVED') },
]);

const triggerEventOptions = computed(() =>
  FLOW_TRIGGER_OPTIONS.map(option => ({
    ...option,
    label: translateTriggerOption(option.value),
  }))
);

const conditionFieldOptions = computed(() =>
  FLOW_CONDITION_FIELD_OPTIONS.map(option => ({
    ...option,
    label: translateConditionFieldOption(option.value),
  }))
);

const conditionOperatorOptions = computed(() =>
  FLOW_CONDITION_OPERATOR_OPTIONS.map(option => ({
    ...option,
    label: translateConditionOperatorOption(option.value),
  }))
);

const webhookMethodOptions = computed(() => [
  { value: 'POST', label: 'POST' },
  { value: 'GET', label: 'GET' },
]);

const triggerSummary = computed(() => getTriggerSummary(flowConfig.value));

const formControlClass =
  'w-full rounded-2xl border border-n-weak bg-white px-3 py-2.5 text-sm text-n-slate-12 shadow-sm outline-none transition focus:border-n-blue-8 focus:ring-2 focus:ring-n-blue-5/40';

const textareaControlClass = `${formControlClass} min-h-[7rem] resize-y`;

const escapeHtml = value =>
  value
    ?.toString()
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;') || '';

const nodeTintClass = type =>
  `ol-flow-node--${FLOW_NODE_DEFINITIONS[type]?.tint || 'slate'}`;

const nodeTitle = type => {
  return translateNodeTitle(type);
};

const triggerEventLabel = event => translateTriggerOption(event);

const conditionFieldLabel = value => translateConditionFieldOption(value);

const conditionOperatorLabel = value => translateConditionOperatorOption(value);

const summarizeNode = node => {
  const data = node.data || {};

  switch (node.name) {
    case 'trigger':
      return data.event === 'keyword' && data.keywords?.length
        ? `${triggerEventLabel(data.event)}: ${data.keywords.join(', ')}`
        : triggerEventLabel(data.event || 'all_messages');
    case 'message':
    case 'note':
      return data.body || t('AGENT_BOTS.BUILDER.NODE_SUMMARY.EMPTY_BODY');
    case 'menu':
      return data.body || t('AGENT_BOTS.BUILDER.NODE_SUMMARY.EMPTY_MENU');
    case 'condition':
      if (data.field === 'has_label') {
        const labelNames = (data.label_ids || [])
          .map(labelId => labelsById.value[labelId])
          .filter(Boolean);
        return (
          labelNames.join(', ') ||
          t('AGENT_BOTS.BUILDER.NODE_SUMMARY.NO_LABELS')
        );
      }

      return `${conditionFieldLabel(data.field)} ${conditionOperatorLabel(
        data.operator
      )} ${data.value || '…'}`;
    case 'delay':
      return t('AGENT_BOTS.BUILDER.NODE_SUMMARY.DELAY', {
        seconds: Number(data.seconds || 0),
      });
    case 'add_label':
    case 'remove_label': {
      const labelNames = (data.label_ids || [])
        .map(labelId => labelsById.value[labelId])
        .filter(Boolean);
      return (
        labelNames.join(', ') || t('AGENT_BOTS.BUILDER.NODE_SUMMARY.NO_LABELS')
      );
    }
    case 'assign_team':
      return (
        teamsById.value[data.team_id] ||
        t('AGENT_BOTS.BUILDER.NODE_SUMMARY.NOT_SET')
      );
    case 'assign_agent':
      return (
        agentsById.value[data.agent_id] ||
        t('AGENT_BOTS.BUILDER.NODE_SUMMARY.NOT_SET')
      );
    case 'change_status':
    case 'handoff':
      return (
        statusOptions.value.find(option => option.value === data.status)
          ?.label || t('AGENT_BOTS.BUILDER.STATUS.OPEN')
      );
    case 'webhook':
      return data.url || t('AGENT_BOTS.BUILDER.NODE_SUMMARY.NOT_SET');
    default:
      return '';
  }
};

const nodeBadges = node => {
  const data = node.data || {};

  switch (node.name) {
    case 'menu':
      return (data.options || [])
        .slice(0, 4)
        .map(option => option.label)
        .filter(Boolean);
    case 'condition':
      return [
        t('AGENT_BOTS.BUILDER.BRANCH.YES'),
        t('AGENT_BOTS.BUILDER.BRANCH.NO'),
      ];
    case 'handoff':
      return data.disable_bot
        ? [t('AGENT_BOTS.BUILDER.HANDOFF_PAUSE')]
        : [t('AGENT_BOTS.BUILDER.HANDOFF_CONTINUES')];
    default:
      return [];
  }
};

const nodeMarkup = node => {
  const definition = FLOW_NODE_DEFINITIONS[node.name] || {};
  const summary = summarizeNode(node);
  const badges = nodeBadges(node);
  const badgesHtml = badges.length
    ? `<div class="ol-flow-node__badges">${badges
        .map(
          badge =>
            `<span class="ol-flow-node__badge">${escapeHtml(badge)}</span>`
        )
        .join('')}</div>`
    : '';

  return `
    <div class="ol-flow-node ${nodeTintClass(node.name)}">
      <div class="ol-flow-node__header">
        <span class="ol-flow-node__icon">
          <i class="${escapeHtml(definition.icon || 'i-lucide-circle')}"></i>
        </span>
        <div class="ol-flow-node__heading">
          <p class="ol-flow-node__title">${escapeHtml(nodeTitle(node.name))}</p>
          <p class="ol-flow-node__type">${escapeHtml(
            translateNodeDescription(node.name)
          )}</p>
        </div>
      </div>
      <p class="ol-flow-node__summary">${escapeHtml(summary)}</p>
      ${badgesHtml}
    </div>
  `;
};

const updateEditorSnapshot = ({ markDirty = true } = {}) => {
  if (!editor.value) return;

  flowConfig.value = {
    ...flowConfig.value,
    flow: editor.value.export(),
  };

  if (markDirty) {
    isDirty.value = true;
  }
};

const updateRenderedNode = nodeId => {
  const node = flowNodes.value[nodeId];
  if (!node) return;

  const nodeElement = document.getElementById(`node-${nodeId}`);
  const contentElement = nodeElement?.querySelector('.drawflow_content_node');
  const markup = nodeMarkup(node);

  if (contentElement) {
    contentElement.innerHTML = markup;
  }

  const drawflowNode = editor.value?.drawflow?.drawflow?.Home?.data?.[nodeId];
  if (drawflowNode) {
    drawflowNode.html = markup;
  }
};

const refreshAllRenderedNodes = () => {
  Object.keys(flowNodes.value).forEach(updateRenderedNode);
};

const bindEditorEvents = instance => {
  instance.on('nodeSelected', id => {
    selectedNodeId.value = `${id}`;
  });

  instance.on('nodeUnselected', () => {
    selectedNodeId.value = '';
  });

  instance.on('nodeRemoved', id => {
    if (selectedNodeId.value === `${id}`) {
      selectedNodeId.value = '';
    }
  });

  instance.on('zoom', value => {
    zoomLevel.value = Number(value || 1);
  });

  [
    'nodeCreated',
    'nodeRemoved',
    'nodeMoved',
    'connectionCreated',
    'connectionRemoved',
  ].forEach(eventName => {
    instance.on(eventName, () => {
      updateEditorSnapshot();
      nextTick(refreshAllRenderedNodes);
    });
  });

  instance.on('import', () => {
    updateEditorSnapshot({ markDirty: false });
    nextTick(refreshAllRenderedNodes);
  });
};

const destroyEditor = () => {
  if (editorCanvasRef.value) {
    editorCanvasRef.value.innerHTML = '';
  }

  editor.value = null;
};

const initializeEditor = async () => {
  if (!editorCanvasRef.value || !isFlowBot.value) return;

  destroyEditor();
  await nextTick();

  const instance = new Drawflow(editorCanvasRef.value);
  instance.useuuid = true;
  instance.reroute = true;
  instance.zoom_max = 1.6;
  instance.zoom_min = 0.4;
  instance.zoom_value = 0.1;
  instance.start();
  bindEditorEvents(instance);
  instance.import(flowConfig.value.flow);
  editor.value = instance;
  zoomLevel.value = instance.zoom;
  await nextTick();
  refreshAllRenderedNodes();
};

const initializeFromBot = async currentBot => {
  if (!currentBot?.id || initializedBotId.value === currentBot.id) return;

  botMeta.name = currentBot.name || '';
  botMeta.description = currentBot.description || '';
  flowConfig.value = cloneFlowConfig(currentBot.bot_config);
  initializedBotId.value = currentBot.id;
  selectedNodeId.value = '';

  await nextTick();

  if (currentBot.bot_type === 'flow_builder') {
    await initializeEditor();
  } else {
    destroyEditor();
  }

  isDirty.value = false;
  isBooting.value = false;
};

const loadContext = async () => {
  isBooting.value = true;

  await Promise.all([
    store.dispatch('agentBots/show', route.params.botId),
    store.dispatch('labels/get'),
    store.dispatch('teams/get'),
    store.dispatch('agents/get'),
  ]);

  if (!bot.value?.id) {
    isBooting.value = false;
  }
};

const toCanvasCoordinates = (clientX, clientY) => {
  const rect = editor.value.precanvas.getBoundingClientRect();

  return {
    x: (clientX - rect.x) / editor.value.zoom,
    y: (clientY - rect.y) / editor.value.zoom,
  };
};

const createNode = (type, position) => {
  if (!editor.value) return;

  const node = buildNodeRecord({
    type,
    x: position.x,
    y: position.y,
  });

  const createdId = editor.value.addNode(
    type,
    FLOW_NODE_DEFINITIONS[type]?.inputs ?? 1,
    getOutputCount(type, node.data),
    node.pos_x,
    node.pos_y,
    type,
    node.data,
    nodeMarkup(node)
  );

  updateEditorSnapshot();
  selectedNodeId.value = `${createdId}`;
  nextTick(() => updateRenderedNode(`${createdId}`));
};

const isPointInsideCanvas = (clientX, clientY) => {
  if (!canvasShellRef.value) return false;

  const rect = canvasShellRef.value.getBoundingClientRect();

  return (
    clientX >= rect.left &&
    clientX <= rect.right &&
    clientY >= rect.top &&
    clientY <= rect.bottom
  );
};

const armNodePlacement = type => {
  armedNodeType.value = armedNodeType.value === type ? '' : type;
};

const handlePaletteDragStart = (event, type) => {
  draggedNodeType.value = type;
  armedNodeType.value = '';

  if (event.dataTransfer) {
    event.dataTransfer.setData('text/plain', type);
    event.dataTransfer.effectAllowed = 'copy';
  }
};

const handlePaletteDragEnd = () => {
  draggedNodeType.value = '';
};

const handleDocumentDragOver = event => {
  if (!draggedNodeType.value) return;

  event.preventDefault();
};

const handleDocumentDrop = event => {
  const droppedType =
    draggedNodeType.value || event.dataTransfer?.getData('text/plain');

  if (!droppedType) return;

  draggedNodeType.value = '';

  if (!editor.value || !isPointInsideCanvas(event.clientX, event.clientY)) {
    return;
  }

  event.preventDefault();
  createNode(droppedType, toCanvasCoordinates(event.clientX, event.clientY));
};

const handleCanvasClick = event => {
  if (!armedNodeType.value || !editor.value) return;
  if (event.target.closest?.('.drawflow-node')) return;

  createNode(
    armedNodeType.value,
    toCanvasCoordinates(event.clientX, event.clientY)
  );
  armedNodeType.value = '';
};

const removeSelectedNode = () => {
  if (!editor.value || !selectedNodeId.value) return;

  editor.value.removeNodeId(`node-${selectedNodeId.value}`);
  selectedNodeId.value = '';
  updateEditorSnapshot();
};

const syncMenuOutputs = (nodeId, optionCount) => {
  if (!editor.value) return;

  const currentNode = editor.value.getNodeFromId(nodeId);
  const currentOutputs = Object.keys(currentNode.outputs || {}).length;
  const nextOutputs = Math.max(optionCount, 1);

  if (currentOutputs < nextOutputs) {
    Array.from({ length: nextOutputs - currentOutputs }).forEach(() => {
      editor.value.addNodeOutput(nodeId);
    });
  }

  if (currentOutputs > nextOutputs) {
    for (
      let outputIndex = currentOutputs;
      outputIndex > nextOutputs;
      outputIndex -= 1
    ) {
      editor.value.removeNodeOutput(nodeId, `output_${outputIndex}`);
    }
  }
};

const updateInspectorNodeData = updater => {
  if (!editor.value || !inspectorNode.value) return;

  const nodeId = inspectorNode.value.id;
  const previousData = JSON.parse(
    JSON.stringify(inspectorNode.value.data || {})
  );
  const nextData =
    typeof updater === 'function' ? updater(previousData) : updater;

  editor.value.updateNodeDataFromId(nodeId, nextData);

  if (inspectorNode.value.name === 'menu') {
    syncMenuOutputs(nodeId, (nextData.options || []).length);
  }

  updateEditorSnapshot();
  nextTick(() => updateRenderedNode(nodeId));
};

const updateBotMeta = (key, value) => {
  botMeta[key] = value;
  isDirty.value = true;
};

const updateTriggerKeywords = value => {
  updateInspectorNodeData(currentData => ({
    ...currentData,
    keywords: value
      .split(',')
      .map(keyword => keyword.trim())
      .filter(Boolean),
  }));
};

const updateLabelSelection = labelId => {
  const currentIds = new Set(inspectorNode.value?.data?.label_ids || []);
  if (currentIds.has(labelId)) {
    currentIds.delete(labelId);
  } else {
    currentIds.add(labelId);
  }

  updateInspectorNodeData(currentData => ({
    ...currentData,
    label_ids: Array.from(currentIds),
  }));
};

const updateMenuOption = (optionId, key, value) => {
  updateInspectorNodeData(currentData => ({
    ...currentData,
    options: (currentData.options || []).map(option =>
      option.id === optionId ? { ...option, [key]: value } : option
    ),
  }));
};

const addMenuOption = () => {
  updateInspectorNodeData(currentData => ({
    ...currentData,
    options: [
      ...(currentData.options || []),
      {
        id: `option_${Date.now()}`,
        label: '',
        value: '',
      },
    ],
  }));
};

const removeMenuOption = optionId => {
  updateInspectorNodeData(currentData => ({
    ...currentData,
    options: (currentData.options || []).filter(
      option => option.id !== optionId
    ),
  }));
};

const saveFlow = async () => {
  if (!bot.value?.id || !editor.value) return;
  if (!botMeta.name.trim()) {
    useAlert(t('AGENT_BOTS.FORM.ERRORS.NAME'));
    return;
  }

  if (
    triggerSummary.value.event === 'keyword' &&
    !triggerSummary.value.keywords.length
  ) {
    useAlert(t('AGENT_BOTS.BUILDER.ERRORS.KEYWORDS_REQUIRED'));
    return;
  }

  const hasEmptyMessages = nodeList.value.some(
    node =>
      ['message', 'menu', 'note'].includes(node.name) &&
      !(node.data?.body || '').trim()
  );

  if (hasEmptyMessages) {
    useAlert(t('AGENT_BOTS.BUILDER.ERRORS.STEP_BODY_REQUIRED'));
    return;
  }

  const hasEmptyMenuOptions = nodeList.value.some(
    node =>
      node.name === 'menu' &&
      (node.data?.options || []).some(option => !(option.label || '').trim())
  );

  if (hasEmptyMenuOptions) {
    useAlert(t('AGENT_BOTS.BUILDER.ERRORS.MENU_OPTION_REQUIRED'));
    return;
  }

  isSaving.value = true;

  try {
    const response = await store.dispatch('agentBots/update', {
      id: bot.value.id,
      data: {
        name: botMeta.name.trim(),
        description: botMeta.description.trim(),
        bot_type: 'flow_builder',
        outgoing_url: '',
        bot_config: {
          ...flowConfig.value,
          flow: editor.value.export(),
        },
      },
    });

    flowConfig.value = cloneFlowConfig(
      response?.bot_config || flowConfig.value
    );
    isDirty.value = false;
    useAlert(t('AGENT_BOTS.BUILDER.SAVE_SUCCESS'));
  } catch (error) {
    useAlert(t('AGENT_BOTS.BUILDER.SAVE_ERROR'));
  } finally {
    isSaving.value = false;
  }
};

const autoLayout = () => {
  if (!editor.value) return;

  const nodes = getFlowData(flowConfig.value);
  const levels = new Map();
  const visited = new Set();
  const queue = triggerNodes.value.map(node => ({ id: node.id, depth: 0 }));

  while (queue.length) {
    const current = queue.shift();
    if (current && !visited.has(current.id)) {
      visited.add(current.id);
      if (!levels.has(current.depth)) {
        levels.set(current.depth, []);
      }

      levels.get(current.depth).push(current.id);
      const currentNode = nodes[current.id];

      Object.values(currentNode.outputs || {}).forEach(output => {
        (output.connections || []).forEach(connection => {
          queue.push({
            id: `${connection.node}`,
            depth: current.depth + 1,
          });
        });
      });
    }
  }

  let orphanDepth = levels.size;
  Object.keys(nodes).forEach(nodeId => {
    if (visited.has(nodeId)) return;

    if (!levels.has(orphanDepth)) {
      levels.set(orphanDepth, []);
    }

    levels.get(orphanDepth).push(nodeId);
    orphanDepth += 1;
  });

  levels.forEach((nodeIds, depth) => {
    nodeIds.forEach((nodeId, row) => {
      const x = 120 + depth * 360;
      const y = 100 + row * 220;
      const drawflowNode = editor.value.drawflow.drawflow.Home.data[nodeId];
      if (!drawflowNode) return;

      drawflowNode.pos_x = x;
      drawflowNode.pos_y = y;

      const element = document.getElementById(`node-${nodeId}`);
      if (element) {
        element.style.left = `${x}px`;
        element.style.top = `${y}px`;
      }

      editor.value.updateConnectionNodes(`node-${nodeId}`);
    });
  });

  updateEditorSnapshot();
};

const downloadFlow = () => {
  const payload = JSON.stringify(
    {
      name: botMeta.name,
      description: botMeta.description,
      ...flowConfig.value,
      flow: editor.value?.export() || flowConfig.value.flow,
    },
    null,
    2
  );
  const blob = new Blob([payload], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = `${botMeta.name || 'flow-builder'}.json`;
  link.click();
  URL.revokeObjectURL(url);
};

const openImportDialog = () => {
  fileInputRef.value?.click();
};

const handleImport = async event => {
  const [file] = event.target.files || [];
  if (!file) return;

  try {
    const text = await file.text();
    const parsed = JSON.parse(text);
    const importedConfig = cloneFlowConfig(parsed);
    flowConfig.value = importedConfig;
    botMeta.name = parsed.name || botMeta.name;
    botMeta.description = parsed.description || botMeta.description;
    await initializeEditor();
    isDirty.value = true;
    useAlert(t('AGENT_BOTS.BUILDER.IMPORT_SUCCESS'));
  } catch (error) {
    useAlert(t('AGENT_BOTS.BUILDER.IMPORT_ERROR'));
  } finally {
    event.target.value = '';
  }
};

const zoomIn = () => editor.value?.zoom_in();
const zoomOut = () => editor.value?.zoom_out();
const zoomReset = () => editor.value?.zoom_reset();

watch(
  () => bot.value?.id,
  async botId => {
    if (!botId) return;

    await initializeFromBot(bot.value);
  },
  { immediate: true }
);

useEventListener(window, 'keydown', event => {
  if (event.key === 'Escape' && armedNodeType.value) {
    armedNodeType.value = '';
    return;
  }

  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 's') {
    event.preventDefault();
    saveFlow();
  }
});

useEventListener(editorCanvasRef, 'click', handleCanvasClick, {
  capture: true,
});
useEventListener(document, 'dragover', handleDocumentDragOver);
useEventListener(document, 'drop', handleDocumentDrop);

useEventListener(window, 'beforeunload', event => {
  if (!isDirty.value) return;

  event.preventDefault();
  event.returnValue = '';
});

onBeforeRouteLeave((_to, _from, next) => {
  if (!isDirty.value) {
    next();
    return;
  }

  // eslint-disable-next-line no-alert
  if (window.confirm(t('AGENT_BOTS.BUILDER.UNSAVED_CONFIRM'))) {
    next();
    return;
  }

  next(false);
});

onMounted(loadContext);
</script>

<template>
  <div class="flex min-h-[calc(100vh-4rem)] flex-col bg-n-alpha-1">
    <header
      class="sticky top-0 z-20 border-b border-n-weak bg-white/90 px-6 py-4 backdrop-blur"
    >
      <div class="flex flex-wrap items-center justify-between gap-4">
        <div class="flex items-center gap-3">
          <Button
            variant="faded"
            size="sm"
            color="slate"
            icon="i-lucide-arrow-left"
            @click="
              router.push({
                name: 'agent_bots',
                params: { accountId: route.params.accountId },
              })
            "
          />
          <div>
            <p class="mb-0 text-base font-semibold text-n-slate-12">
              {{ botMeta.name || t('AGENT_BOTS.BUILDER.HEADER') }}
            </p>
            <p class="mb-0 text-sm text-n-slate-11">
              {{ t('AGENT_BOTS.BUILDER.DESCRIPTION') }}
            </p>
          </div>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <span
            class="rounded-full border border-n-weak bg-white px-3 py-1 text-xs font-medium text-n-slate-11"
          >
            {{ nodeCount }} {{ t('AGENT_BOTS.BUILDER.STEPS_COUNT') }}
          </span>
          <span
            class="rounded-full border border-n-weak bg-white px-3 py-1 text-xs font-medium text-n-slate-11"
          >
            {{ connectionCount }}
            {{ t('AGENT_BOTS.BUILDER.CONNECTIONS_COUNT') }}
          </span>
          <Button
            variant="faded"
            size="sm"
            color="slate"
            icon="i-lucide-layout-grid"
            :label="t('AGENT_BOTS.BUILDER.AUTO_LAYOUT')"
            @click="autoLayout"
          />
          <Button
            variant="faded"
            size="sm"
            color="slate"
            icon="i-lucide-download"
            :label="t('AGENT_BOTS.BUILDER.EXPORT')"
            @click="downloadFlow"
          />
          <Button
            variant="faded"
            size="sm"
            color="slate"
            icon="i-lucide-upload"
            :label="t('AGENT_BOTS.BUILDER.IMPORT')"
            @click="openImportDialog"
          />
          <Button
            icon="i-lucide-save"
            :label="t('AGENT_BOTS.BUILDER.SAVE')"
            :is-loading="isSaving"
            @click="saveFlow"
          />
        </div>
      </div>
      <input
        ref="fileInputRef"
        type="file"
        accept=".json,application/json"
        class="hidden"
        @change="handleImport"
      />
    </header>

    <div
      v-if="isLoading"
      class="flex min-h-[calc(100vh-12rem)] items-center justify-center text-n-slate-11"
    >
      <Spinner />
    </div>

    <div
      v-else-if="!isFlowBot"
      class="flex min-h-[calc(100vh-12rem)] items-center justify-center px-6"
    >
      <div
        class="max-w-xl rounded-3xl border border-n-weak bg-white p-8 text-center shadow-sm"
      >
        <p class="mb-2 text-lg font-semibold text-n-slate-12">
          {{ t('AGENT_BOTS.BUILDER.NOT_FOUND_TITLE') }}
        </p>
        <p class="mb-6 text-sm text-n-slate-11">
          {{ t('AGENT_BOTS.BUILDER.NOT_FOUND_SUBTITLE') }}
        </p>
        <Button
          icon="i-lucide-arrow-left"
          :label="t('AGENT_BOTS.BUILDER.BACK')"
          @click="
            router.push({
              name: 'agent_bots',
              params: { accountId: route.params.accountId },
            })
          "
        />
      </div>
    </div>

    <div
      v-else
      class="grid min-h-0 flex-1 gap-4 px-6 py-6 xl:grid-cols-[21rem_minmax(0,1fr)_18rem]"
    >
      <aside
        class="flex min-h-0 flex-col overflow-hidden rounded-[1.75rem] border border-n-weak bg-white shadow-sm"
      >
        <div class="border-b border-n-weak px-5 py-4">
          <p class="mb-1 text-sm font-semibold text-n-slate-12">
            {{ t('AGENT_BOTS.BUILDER.SETTINGS_TITLE') }}
          </p>
          <p class="mb-0 text-sm text-n-slate-11">
            {{ t('AGENT_BOTS.BUILDER.BOT_SETTINGS_SUBTITLE') }}
          </p>
        </div>

        <div class="flex-1 space-y-6 overflow-y-auto px-5 py-5">
          <section class="space-y-3">
            <label class="block text-sm font-medium text-n-slate-12">
              {{ t('AGENT_BOTS.FORM.NAME.LABEL') }}
            </label>
            <input
              :value="botMeta.name"
              :class="formControlClass"
              :placeholder="t('AGENT_BOTS.FORM.NAME.PLACEHOLDER')"
              @input="updateBotMeta('name', $event.target.value)"
            />

            <label class="block text-sm font-medium text-n-slate-12">
              {{ t('AGENT_BOTS.FORM.DESCRIPTION.LABEL') }}
            </label>
            <textarea
              :value="botMeta.description"
              :class="textareaControlClass"
              :placeholder="t('AGENT_BOTS.FORM.DESCRIPTION.PLACEHOLDER')"
              @input="updateBotMeta('description', $event.target.value)"
            />
          </section>

          <section
            v-if="inspectorNode"
            class="rounded-[1.5rem] border border-n-weak bg-n-alpha-1 p-4"
          >
            <div class="mb-4 flex items-start justify-between gap-3">
              <div>
                <p class="mb-1 text-sm font-semibold text-n-slate-12">
                  {{ nodeTitle(inspectorNode.name) }}
                </p>
                <p class="mb-0 text-sm text-n-slate-11">
                  {{ summarizeNode(inspectorNode) }}
                </p>
              </div>
              <Button
                v-if="canDeleteSelectedNode && selectedNode"
                variant="faded"
                size="sm"
                color="ruby"
                icon="i-lucide-trash"
                @click="removeSelectedNode"
              />
            </div>

            <div v-if="inspectorNode.name === 'trigger'" class="space-y-4">
              <div>
                <label class="mb-2 block text-sm font-medium text-n-slate-12">
                  {{ t('AGENT_BOTS.BUILDER.TRIGGER_EVENT_LABEL') }}
                </label>
                <select
                  :value="inspectorNode.data.event"
                  :class="formControlClass"
                  @change="
                    updateInspectorNodeData(currentData => ({
                      ...currentData,
                      event: $event.target.value,
                    }))
                  "
                >
                  <option
                    v-for="option in triggerEventOptions"
                    :key="option.value"
                    :value="option.value"
                  >
                    {{ option.label }}
                  </option>
                </select>
              </div>

              <div v-if="inspectorNode.data.event === 'keyword'">
                <label class="mb-2 block text-sm font-medium text-n-slate-12">
                  {{ t('AGENT_BOTS.BUILDER.KEYWORDS_LABEL') }}
                </label>
                <textarea
                  :value="(inspectorNode.data.keywords || []).join(', ')"
                  :class="textareaControlClass"
                  :placeholder="t('AGENT_BOTS.BUILDER.KEYWORDS_PLACEHOLDER')"
                  @input="updateTriggerKeywords($event.target.value)"
                />
              </div>
            </div>

            <div
              v-else-if="['message', 'note'].includes(inspectorNode.name)"
              class="space-y-3"
            >
              <label class="block text-sm font-medium text-n-slate-12">
                {{ t('AGENT_BOTS.BUILDER.BODY_LABEL') }}
              </label>
              <textarea
                :value="inspectorNode.data.body"
                :class="textareaControlClass"
                :placeholder="t('AGENT_BOTS.BUILDER.BODY_PLACEHOLDER')"
                @input="
                  updateInspectorNodeData(currentData => ({
                    ...currentData,
                    body: $event.target.value,
                  }))
                "
              />
            </div>

            <div v-else-if="inspectorNode.name === 'menu'" class="space-y-4">
              <div>
                <label class="mb-2 block text-sm font-medium text-n-slate-12">
                  {{ t('AGENT_BOTS.BUILDER.BODY_LABEL') }}
                </label>
                <textarea
                  :value="inspectorNode.data.body"
                  :class="textareaControlClass"
                  :placeholder="t('AGENT_BOTS.BUILDER.BODY_PLACEHOLDER')"
                  @input="
                    updateInspectorNodeData(currentData => ({
                      ...currentData,
                      body: $event.target.value,
                    }))
                  "
                />
              </div>

              <div class="space-y-3">
                <div class="flex items-center justify-between gap-3">
                  <div>
                    <p class="mb-0 text-sm font-medium text-n-slate-12">
                      {{ t('AGENT_BOTS.BUILDER.MENU_OPTIONS') }}
                    </p>
                    <p class="mb-0 text-xs text-n-slate-11">
                      {{ t('AGENT_BOTS.BUILDER.MENU_HELP') }}
                    </p>
                  </div>
                  <Button
                    variant="faded"
                    size="sm"
                    color="slate"
                    icon="i-lucide-plus"
                    :label="t('AGENT_BOTS.BUILDER.ADD_OPTION')"
                    @click="addMenuOption"
                  />
                </div>

                <article
                  v-for="(option, index) in inspectorNode.data.options"
                  :key="option.id"
                  class="rounded-2xl border border-n-weak bg-white p-3"
                >
                  <div class="mb-3 flex items-center justify-between gap-3">
                    <p class="mb-0 text-sm font-medium text-n-slate-12">
                      {{
                        t('AGENT_BOTS.BUILDER.OPTION_LABEL', {
                          index: index + 1,
                        })
                      }}
                    </p>
                    <Button
                      v-if="(inspectorNode.data.options || []).length > 1"
                      variant="faded"
                      size="sm"
                      color="ruby"
                      icon="i-lucide-trash"
                      @click="removeMenuOption(option.id)"
                    />
                  </div>
                  <div class="space-y-3">
                    <input
                      :value="option.label"
                      :class="formControlClass"
                      :placeholder="t('AGENT_BOTS.BUILDER.OPTION_PLACEHOLDER')"
                      @input="
                        updateMenuOption(
                          option.id,
                          'label',
                          $event.target.value
                        )
                      "
                    />
                    <input
                      :value="option.value"
                      :class="formControlClass"
                      :placeholder="
                        t('AGENT_BOTS.BUILDER.MATCH_VALUE_PLACEHOLDER')
                      "
                      @input="
                        updateMenuOption(
                          option.id,
                          'value',
                          $event.target.value
                        )
                      "
                    />
                  </div>
                </article>
              </div>

              <div>
                <label class="mb-2 block text-sm font-medium text-n-slate-12">
                  {{ t('AGENT_BOTS.BUILDER.INVALID_REPLY_LABEL') }}
                </label>
                <textarea
                  :value="inspectorNode.data.invalid_reply_message"
                  :class="textareaControlClass"
                  :placeholder="
                    t('AGENT_BOTS.BUILDER.INVALID_REPLY_PLACEHOLDER')
                  "
                  @input="
                    updateInspectorNodeData(currentData => ({
                      ...currentData,
                      invalid_reply_message: $event.target.value,
                    }))
                  "
                />
              </div>
            </div>

            <div
              v-else-if="inspectorNode.name === 'condition'"
              class="space-y-4"
            >
              <div>
                <label class="mb-2 block text-sm font-medium text-n-slate-12">
                  {{ t('AGENT_BOTS.BUILDER.CONDITION_FIELD_LABEL') }}
                </label>
                <select
                  :value="inspectorNode.data.field"
                  :class="formControlClass"
                  @change="
                    updateInspectorNodeData(currentData => ({
                      ...currentData,
                      field: $event.target.value,
                    }))
                  "
                >
                  <option
                    v-for="option in conditionFieldOptions"
                    :key="option.value"
                    :value="option.value"
                  >
                    {{ option.label }}
                  </option>
                </select>
              </div>

              <div v-if="inspectorNode.data.field !== 'has_label'">
                <label class="mb-2 block text-sm font-medium text-n-slate-12">
                  {{ t('AGENT_BOTS.BUILDER.CONDITION_OPERATOR_LABEL') }}
                </label>
                <select
                  :value="inspectorNode.data.operator"
                  :class="formControlClass"
                  @change="
                    updateInspectorNodeData(currentData => ({
                      ...currentData,
                      operator: $event.target.value,
                    }))
                  "
                >
                  <option
                    v-for="option in conditionOperatorOptions"
                    :key="option.value"
                    :value="option.value"
                  >
                    {{ option.label }}
                  </option>
                </select>
              </div>

              <div v-if="inspectorNode.data.field !== 'has_label'">
                <label class="mb-2 block text-sm font-medium text-n-slate-12">
                  {{ t('AGENT_BOTS.BUILDER.CONDITION_VALUE_LABEL') }}
                </label>
                <input
                  :value="inspectorNode.data.value"
                  :class="formControlClass"
                  :placeholder="
                    t('AGENT_BOTS.BUILDER.CONDITION_VALUE_PLACEHOLDER')
                  "
                  @input="
                    updateInspectorNodeData(currentData => ({
                      ...currentData,
                      value: $event.target.value,
                    }))
                  "
                />
              </div>

              <div
                v-else
                class="space-y-2 rounded-2xl border border-n-weak bg-white p-3"
              >
                <label class="block text-sm font-medium text-n-slate-12">
                  {{ t('AGENT_BOTS.BUILDER.LABELS_LABEL') }}
                </label>
                <button
                  v-for="label in labels"
                  :key="label.id"
                  type="button"
                  class="mr-2 mt-2 rounded-full border px-3 py-1.5 text-xs font-medium transition"
                  :class="
                    (inspectorNode.data.label_ids || []).includes(
                      String(label.id)
                    )
                      ? 'border-n-blue-8 bg-n-blue-2 text-n-blue-11'
                      : 'border-n-weak bg-n-alpha-1 text-n-slate-11'
                  "
                  @click="updateLabelSelection(String(label.id))"
                >
                  {{ label.title || label.name }}
                </button>
              </div>
            </div>

            <div v-else-if="inspectorNode.name === 'delay'" class="space-y-3">
              <label class="block text-sm font-medium text-n-slate-12">
                {{ t('AGENT_BOTS.BUILDER.DELAY_LABEL') }}
              </label>
              <input
                type="number"
                min="1"
                max="86400"
                :value="inspectorNode.data.seconds"
                :class="formControlClass"
                @input="
                  updateInspectorNodeData(currentData => ({
                    ...currentData,
                    seconds: Number($event.target.value || 1),
                  }))
                "
              />
            </div>

            <div
              v-else-if="
                ['add_label', 'remove_label'].includes(inspectorNode.name)
              "
              class="space-y-2 rounded-2xl border border-n-weak bg-white p-3"
            >
              <label class="block text-sm font-medium text-n-slate-12">
                {{ t('AGENT_BOTS.BUILDER.LABELS_LABEL') }}
              </label>
              <button
                v-for="label in labels"
                :key="label.id"
                type="button"
                class="mr-2 mt-2 rounded-full border px-3 py-1.5 text-xs font-medium transition"
                :class="
                  (inspectorNode.data.label_ids || []).includes(
                    String(label.id)
                  )
                    ? 'border-n-blue-8 bg-n-blue-2 text-n-blue-11'
                    : 'border-n-weak bg-n-alpha-1 text-n-slate-11'
                "
                @click="updateLabelSelection(String(label.id))"
              >
                {{ label.title || label.name }}
              </button>
            </div>

            <div
              v-else-if="
                ['assign_team', 'assign_agent', 'change_status'].includes(
                  inspectorNode.name
                )
              "
              class="space-y-4"
            >
              <div v-if="inspectorNode.name === 'assign_team'">
                <label class="mb-2 block text-sm font-medium text-n-slate-12">
                  {{ t('AGENT_BOTS.BUILDER.TEAM_LABEL') }}
                </label>
                <select
                  :value="inspectorNode.data.team_id"
                  :class="formControlClass"
                  @change="
                    updateInspectorNodeData(currentData => ({
                      ...currentData,
                      team_id: $event.target.value,
                    }))
                  "
                >
                  <option value="">
                    {{ t('AGENT_BOTS.BUILDER.TEAM_PLACEHOLDER') }}
                  </option>
                  <option v-for="team in teams" :key="team.id" :value="team.id">
                    {{ team.name }}
                  </option>
                </select>
              </div>

              <div v-if="inspectorNode.name === 'assign_agent'">
                <label class="mb-2 block text-sm font-medium text-n-slate-12">
                  {{ t('AGENT_BOTS.BUILDER.AGENT_LABEL') }}
                </label>
                <select
                  :value="inspectorNode.data.agent_id"
                  :class="formControlClass"
                  @change="
                    updateInspectorNodeData(currentData => ({
                      ...currentData,
                      agent_id: $event.target.value,
                    }))
                  "
                >
                  <option value="">
                    {{ t('AGENT_BOTS.BUILDER.AGENT_PLACEHOLDER') }}
                  </option>
                  <option
                    v-for="agent in agents"
                    :key="agent.id"
                    :value="agent.id"
                  >
                    {{ agent.name || agent.available_name || agent.email }}
                  </option>
                </select>
              </div>

              <div v-if="inspectorNode.name === 'change_status'">
                <label class="mb-2 block text-sm font-medium text-n-slate-12">
                  {{ t('AGENT_BOTS.BUILDER.STATUS_LABEL') }}
                </label>
                <select
                  :value="inspectorNode.data.status"
                  :class="formControlClass"
                  @change="
                    updateInspectorNodeData(currentData => ({
                      ...currentData,
                      status: $event.target.value,
                    }))
                  "
                >
                  <option
                    v-for="option in statusOptions"
                    :key="option.value"
                    :value="option.value"
                  >
                    {{ option.label }}
                  </option>
                </select>
              </div>
            </div>

            <div v-else-if="inspectorNode.name === 'handoff'" class="space-y-4">
              <div>
                <label class="mb-2 block text-sm font-medium text-n-slate-12">
                  {{ t('AGENT_BOTS.BUILDER.TEAM_LABEL') }}
                </label>
                <select
                  :value="inspectorNode.data.team_id"
                  :class="formControlClass"
                  @change="
                    updateInspectorNodeData(currentData => ({
                      ...currentData,
                      team_id: $event.target.value,
                    }))
                  "
                >
                  <option value="">
                    {{ t('AGENT_BOTS.BUILDER.TEAM_PLACEHOLDER') }}
                  </option>
                  <option v-for="team in teams" :key="team.id" :value="team.id">
                    {{ team.name }}
                  </option>
                </select>
              </div>
              <div>
                <label class="mb-2 block text-sm font-medium text-n-slate-12">
                  {{ t('AGENT_BOTS.BUILDER.AGENT_LABEL') }}
                </label>
                <select
                  :value="inspectorNode.data.agent_id"
                  :class="formControlClass"
                  @change="
                    updateInspectorNodeData(currentData => ({
                      ...currentData,
                      agent_id: $event.target.value,
                    }))
                  "
                >
                  <option value="">
                    {{ t('AGENT_BOTS.BUILDER.AGENT_PLACEHOLDER') }}
                  </option>
                  <option
                    v-for="agent in agents"
                    :key="agent.id"
                    :value="agent.id"
                  >
                    {{ agent.name || agent.available_name || agent.email }}
                  </option>
                </select>
              </div>
              <div>
                <label class="mb-2 block text-sm font-medium text-n-slate-12">
                  {{ t('AGENT_BOTS.BUILDER.STATUS_LABEL') }}
                </label>
                <select
                  :value="inspectorNode.data.status"
                  :class="formControlClass"
                  @change="
                    updateInspectorNodeData(currentData => ({
                      ...currentData,
                      status: $event.target.value,
                    }))
                  "
                >
                  <option
                    v-for="option in statusOptions"
                    :key="option.value"
                    :value="option.value"
                  >
                    {{ option.label }}
                  </option>
                </select>
              </div>
              <div>
                <label class="mb-2 block text-sm font-medium text-n-slate-12">
                  {{ t('AGENT_BOTS.BUILDER.NOTE_LABEL') }}
                </label>
                <textarea
                  :value="inspectorNode.data.note"
                  :class="textareaControlClass"
                  :placeholder="t('AGENT_BOTS.BUILDER.NOTE_PLACEHOLDER')"
                  @input="
                    updateInspectorNodeData(currentData => ({
                      ...currentData,
                      note: $event.target.value,
                    }))
                  "
                />
              </div>
              <label
                class="flex items-center gap-3 rounded-2xl border border-n-weak bg-white px-3 py-3 text-sm text-n-slate-12"
              >
                <input
                  type="checkbox"
                  :checked="inspectorNode.data.disable_bot"
                  @change="
                    updateInspectorNodeData(currentData => ({
                      ...currentData,
                      disable_bot: $event.target.checked,
                    }))
                  "
                />
                <span>
                  {{ t('AGENT_BOTS.BUILDER.DISABLE_BOT_AFTER_HANDOFF') }}
                </span>
              </label>
            </div>

            <div v-else-if="inspectorNode.name === 'webhook'" class="space-y-4">
              <div>
                <label class="mb-2 block text-sm font-medium text-n-slate-12">
                  {{ t('AGENT_BOTS.BUILDER.WEBHOOK_METHOD_LABEL') }}
                </label>
                <select
                  :value="inspectorNode.data.method"
                  :class="formControlClass"
                  @change="
                    updateInspectorNodeData(currentData => ({
                      ...currentData,
                      method: $event.target.value,
                    }))
                  "
                >
                  <option
                    v-for="option in webhookMethodOptions"
                    :key="option.value"
                    :value="option.value"
                  >
                    {{ option.label }}
                  </option>
                </select>
              </div>
              <div>
                <label class="mb-2 block text-sm font-medium text-n-slate-12">
                  {{ t('AGENT_BOTS.BUILDER.WEBHOOK_URL_LABEL') }}
                </label>
                <input
                  :value="inspectorNode.data.url"
                  :class="formControlClass"
                  :placeholder="t('AGENT_BOTS.FORM.WEBHOOK_URL.PLACEHOLDER')"
                  @input="
                    updateInspectorNodeData(currentData => ({
                      ...currentData,
                      url: $event.target.value,
                    }))
                  "
                />
              </div>
            </div>
          </section>
        </div>
      </aside>

      <section
        class="flex min-h-[72vh] min-w-0 flex-col overflow-hidden rounded-[2rem] border border-n-weak bg-white shadow-sm"
      >
        <div
          class="flex flex-wrap items-center justify-between gap-3 border-b border-n-weak px-5 py-4"
        >
          <div>
            <p class="mb-1 text-sm font-semibold text-n-slate-12">
              {{ t('AGENT_BOTS.BUILDER.CANVAS_TITLE') }}
            </p>
            <p class="mb-0 text-sm text-n-slate-11">
              {{ t('AGENT_BOTS.BUILDER.CANVAS_SUBTITLE') }}
            </p>
          </div>
          <div class="flex items-center gap-2">
            <Button
              variant="faded"
              size="sm"
              color="slate"
              icon="i-lucide-minus"
              @click="zoomOut"
            />
            <span
              class="rounded-full border border-n-weak px-3 py-1 text-xs font-medium text-n-slate-11"
            >
              {{ `${Math.round(zoomLevel * 100)}%` }}
            </span>
            <Button
              variant="faded"
              size="sm"
              color="slate"
              icon="i-lucide-plus"
              @click="zoomIn"
            />
            <Button
              variant="faded"
              size="sm"
              color="slate"
              icon="i-lucide-scan-search"
              @click="zoomReset"
            />
          </div>
        </div>

        <div
          ref="canvasShellRef"
          class="relative flex-1 overflow-hidden bg-[radial-gradient(circle_at_top_left,rgba(59,130,246,0.08),transparent_32%),radial-gradient(circle_at_bottom_right,rgba(15,23,42,0.08),transparent_38%)]"
          :class="armedNodeType ? 'cursor-crosshair' : ''"
        >
          <div
            v-if="showCanvasEmpty"
            class="pointer-events-none absolute inset-0 z-10 flex items-center justify-center px-6"
          >
            <div
              class="max-w-md rounded-[1.75rem] border border-dashed border-n-blue-6 bg-white/90 p-6 text-center shadow-sm"
            >
              <div
                class="mx-auto mb-4 flex h-14 w-14 items-center justify-center rounded-2xl bg-n-blue-2 text-2xl text-n-blue-11"
              >
                <i class="i-lucide-workflow" />
              </div>
              <p class="mb-2 text-lg font-semibold text-n-slate-12">
                {{ t('AGENT_BOTS.BUILDER.CANVAS_EMPTY_TITLE') }}
              </p>
              <p class="mb-0 text-sm text-n-slate-11">
                {{ t('AGENT_BOTS.BUILDER.CANVAS_EMPTY_SUBTITLE') }}
              </p>
            </div>
          </div>

          <div
            ref="editorCanvasRef"
            class="h-full w-full"
            :class="armedNodeType ? 'cursor-crosshair' : ''"
          />
        </div>
      </section>

      <aside
        class="flex min-h-0 flex-col overflow-hidden rounded-[1.75rem] border border-n-weak bg-white shadow-sm"
      >
        <div class="border-b border-n-weak px-5 py-4">
          <p class="mb-1 text-sm font-semibold text-n-slate-12">
            {{ t('AGENT_BOTS.BUILDER.PALETTE_TITLE') }}
          </p>
          <p class="mb-0 text-sm text-n-slate-11">
            {{ t('AGENT_BOTS.BUILDER.PALETTE_SUBTITLE') }}
          </p>
        </div>

        <div class="flex-1 space-y-5 overflow-y-auto px-5 py-5">
          <section
            v-for="group in paletteGroups"
            :key="group.key"
            class="space-y-3"
          >
            <p
              class="mb-0 text-xs font-semibold uppercase tracking-[0.12em] text-n-slate-11"
            >
              {{ group.label }}
            </p>
            <div
              v-for="item in group.items"
              :key="item.type"
              role="button"
              tabindex="0"
              draggable="true"
              class="flex w-full cursor-grab items-start gap-3 rounded-[1.25rem] border border-n-weak bg-n-alpha-1 px-4 py-3 text-left transition hover:border-n-blue-6 hover:bg-n-blue-2 active:cursor-grabbing"
              :class="
                armedNodeType === item.type
                  ? 'border-n-blue-7 bg-n-blue-2 ring-2 ring-n-blue-5/30'
                  : ''
              "
              @click="armNodePlacement(item.type)"
              @keydown.enter.prevent="armNodePlacement(item.type)"
              @keydown.space.prevent="armNodePlacement(item.type)"
              @dragstart="handlePaletteDragStart($event, item.type)"
              @dragend="handlePaletteDragEnd"
            >
              <span
                class="mt-0.5 flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl bg-white text-lg text-n-slate-12 shadow-sm"
              >
                <i :class="item.icon" />
              </span>
              <span class="min-w-0">
                <span class="block text-sm font-semibold text-n-slate-12">
                  {{ item.title }}
                </span>
                <span class="block text-sm text-n-slate-11">
                  {{ item.description }}
                </span>
              </span>
            </div>
          </section>
        </div>
      </aside>
    </div>
  </div>
</template>

<style scoped>
:deep(.parent-drawflow) {
  height: 100%;
  background-image: radial-gradient(
      circle at center,
      rgba(100, 116, 139, 0.12) 1px,
      transparent 1px
    ),
    linear-gradient(
      135deg,
      rgba(255, 255, 255, 0.94),
      rgba(248, 250, 252, 0.94)
    );
  background-size:
    24px 24px,
    100% 100%;
  outline: none;
}

:deep(.drawflow) {
  width: 100%;
  height: 100%;
}

:deep(.drawflow .drawflow-node) {
  width: 280px;
  min-height: 132px;
  border-radius: 22px;
  border: 1px solid rgb(226 232 240 / 1);
  background: transparent;
  box-shadow:
    0 12px 32px rgb(15 23 42 / 0.08),
    0 1px 2px rgb(15 23 42 / 0.04);
  padding: 0;
  color: inherit;
}

:deep(.drawflow .drawflow-node.selected) {
  border-color: rgb(37 99 235 / 0.5);
  box-shadow:
    0 16px 38px rgb(37 99 235 / 0.18),
    0 0 0 4px rgb(191 219 254 / 0.55);
}

:deep(.drawflow .drawflow-node:hover) {
  cursor: move;
}

:deep(.drawflow .drawflow-node .drawflow_content_node) {
  width: 100%;
}

:deep(.drawflow .drawflow-node .input),
:deep(.drawflow .drawflow-node .output) {
  width: 14px;
  height: 14px;
  border: 2px solid rgb(148 163 184 / 1);
  background: white;
  box-shadow: 0 0 0 4px rgb(255 255 255 / 0.92);
}

:deep(.drawflow .drawflow-node .input:hover),
:deep(.drawflow .drawflow-node .output:hover) {
  border-color: rgb(37 99 235 / 1);
  background: rgb(219 234 254 / 1);
}

:deep(.drawflow .connection .main-path) {
  stroke: rgb(148 163 184 / 0.8);
  stroke-width: 3px;
}

:deep(.drawflow .connection .main-path:hover),
:deep(.drawflow .connection .main-path.selected) {
  stroke: rgb(37 99 235 / 1);
}

:deep(.ol-flow-node) {
  display: flex;
  min-height: 130px;
  flex-direction: column;
  gap: 14px;
  border-radius: 22px;
  background: linear-gradient(
    180deg,
    rgb(255 255 255 / 0.98),
    rgb(248 250 252 / 0.98)
  );
  padding: 18px;
}

:deep(.ol-flow-node__header) {
  display: flex;
  gap: 12px;
  align-items: flex-start;
}

:deep(.ol-flow-node__icon) {
  display: inline-flex;
  height: 42px;
  width: 42px;
  flex-shrink: 0;
  align-items: center;
  justify-content: center;
  border-radius: 16px;
  background: rgb(255 255 255 / 0.88);
  box-shadow:
    inset 0 0 0 1px rgb(226 232 240 / 1),
    0 6px 18px rgb(15 23 42 / 0.08);
  font-size: 20px;
}

:deep(.ol-flow-node__heading) {
  min-width: 0;
}

:deep(.ol-flow-node__title) {
  margin: 0;
  font-size: 14px;
  font-weight: 700;
  color: rgb(15 23 42 / 1);
}

:deep(.ol-flow-node__type) {
  margin: 3px 0 0;
  font-size: 12px;
  color: rgb(100 116 139 / 1);
}

:deep(.ol-flow-node__summary) {
  margin: 0;
  font-size: 13px;
  line-height: 1.5;
  color: rgb(51 65 85 / 1);
}

:deep(.ol-flow-node__badges) {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

:deep(.ol-flow-node__badge) {
  display: inline-flex;
  align-items: center;
  border-radius: 9999px;
  background: rgb(255 255 255 / 0.82);
  padding: 5px 10px;
  font-size: 11px;
  font-weight: 600;
  color: rgb(51 65 85 / 1);
  box-shadow: inset 0 0 0 1px rgb(226 232 240 / 1);
}

:deep(.ol-flow-node--orange) {
  background: radial-gradient(
      circle at top left,
      rgb(255 237 213 / 0.9),
      transparent 42%
    ),
    linear-gradient(180deg, rgb(255 255 255 / 0.98), rgb(255 247 237 / 0.96));
}

:deep(.ol-flow-node--blue) {
  background: radial-gradient(
      circle at top left,
      rgb(219 234 254 / 0.92),
      transparent 42%
    ),
    linear-gradient(180deg, rgb(255 255 255 / 0.98), rgb(239 246 255 / 0.96));
}

:deep(.ol-flow-node--violet) {
  background: radial-gradient(
      circle at top left,
      rgb(237 233 254 / 0.92),
      transparent 42%
    ),
    linear-gradient(180deg, rgb(255 255 255 / 0.98), rgb(245 243 255 / 0.96));
}

:deep(.ol-flow-node--amber) {
  background: radial-gradient(
      circle at top left,
      rgb(254 243 199 / 0.92),
      transparent 42%
    ),
    linear-gradient(180deg, rgb(255 255 255 / 0.98), rgb(255 251 235 / 0.96));
}

:deep(.ol-flow-node--sky) {
  background: radial-gradient(
      circle at top left,
      rgb(224 242 254 / 0.92),
      transparent 42%
    ),
    linear-gradient(180deg, rgb(255 255 255 / 0.98), rgb(240 249 255 / 0.96));
}

:deep(.ol-flow-node--slate) {
  background: radial-gradient(
      circle at top left,
      rgb(226 232 240 / 0.92),
      transparent 42%
    ),
    linear-gradient(180deg, rgb(255 255 255 / 0.98), rgb(248 250 252 / 0.96));
}

:deep(.ol-flow-node--emerald) {
  background: radial-gradient(
      circle at top left,
      rgb(209 250 229 / 0.92),
      transparent 42%
    ),
    linear-gradient(180deg, rgb(255 255 255 / 0.98), rgb(236 253 245 / 0.96));
}

:deep(.ol-flow-node--rose) {
  background: radial-gradient(
      circle at top left,
      rgb(255 228 230 / 0.92),
      transparent 42%
    ),
    linear-gradient(180deg, rgb(255 255 255 / 0.98), rgb(255 241 242 / 0.96));
}

:deep(.ol-flow-node--teal) {
  background: radial-gradient(
      circle at top left,
      rgb(204 251 241 / 0.92),
      transparent 42%
    ),
    linear-gradient(180deg, rgb(255 255 255 / 0.98), rgb(240 253 250 / 0.96));
}

:deep(.ol-flow-node--cyan) {
  background: radial-gradient(
      circle at top left,
      rgb(207 250 254 / 0.92),
      transparent 42%
    ),
    linear-gradient(180deg, rgb(255 255 255 / 0.98), rgb(236 254 255 / 0.96));
}

:deep(.ol-flow-node--indigo) {
  background: radial-gradient(
      circle at top left,
      rgb(224 231 255 / 0.92),
      transparent 42%
    ),
    linear-gradient(180deg, rgb(255 255 255 / 0.98), rgb(238 242 255 / 0.96));
}
</style>
