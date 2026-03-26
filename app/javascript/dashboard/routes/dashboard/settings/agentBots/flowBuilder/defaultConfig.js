const FLOW_VERSION = 2;
const FLOW_MODULE = 'Home';
const DEFAULT_TRIGGER_ID = 'trigger_root';

const createId = prefix => {
  if (typeof crypto !== 'undefined' && crypto.randomUUID) {
    return `${prefix}_${crypto.randomUUID()}`;
  }

  return `${prefix}_${Math.random().toString(36).slice(2, 10)}`;
};

export const FLOW_TRIGGER_OPTIONS = [
  { value: 'all_messages', label: 'AGENT_BOTS.BUILDER.TRIGGERS.ALL_MESSAGES' },
  {
    value: 'first_message',
    label: 'AGENT_BOTS.BUILDER.TRIGGERS.FIRST_MESSAGE',
  },
  { value: 'keyword', label: 'AGENT_BOTS.BUILDER.TRIGGERS.KEYWORD' },
];

export const FLOW_CONDITION_FIELD_OPTIONS = [
  {
    value: 'message_text',
    label: 'AGENT_BOTS.BUILDER.CONDITION_FIELDS.MESSAGE_TEXT',
  },
  {
    value: 'conversation_status',
    label: 'AGENT_BOTS.BUILDER.CONDITION_FIELDS.CONVERSATION_STATUS',
  },
  {
    value: 'has_label',
    label: 'AGENT_BOTS.BUILDER.CONDITION_FIELDS.HAS_LABEL',
  },
];

export const FLOW_CONDITION_OPERATOR_OPTIONS = [
  {
    value: 'contains',
    label: 'AGENT_BOTS.BUILDER.CONDITION_OPERATORS.CONTAINS',
  },
  {
    value: 'equals',
    label: 'AGENT_BOTS.BUILDER.CONDITION_OPERATORS.EQUALS',
  },
];

export const FLOW_NODE_DEFINITIONS = {
  trigger: {
    inputs: 0,
    outputs: 1,
    icon: 'i-lucide-bot',
    group: 'triggers',
    title: 'AGENT_BOTS.BUILDER.NODES.TRIGGER.TITLE',
    description: 'AGENT_BOTS.BUILDER.NODES.TRIGGER.DESCRIPTION',
    tint: 'orange',
  },
  message: {
    inputs: 1,
    outputs: 1,
    icon: 'i-lucide-message-square',
    group: 'messages',
    title: 'AGENT_BOTS.BUILDER.STEPS.MESSAGE',
    description: 'AGENT_BOTS.BUILDER.STEP_HELP.MESSAGE',
    tint: 'blue',
  },
  menu: {
    inputs: 1,
    outputs: 2,
    icon: 'i-lucide-list',
    group: 'messages',
    title: 'AGENT_BOTS.BUILDER.STEPS.MENU',
    description: 'AGENT_BOTS.BUILDER.STEP_HELP.MENU',
    tint: 'violet',
  },
  condition: {
    inputs: 1,
    outputs: 2,
    icon: 'i-lucide-git-branch-plus',
    group: 'logic',
    title: 'AGENT_BOTS.BUILDER.NODES.CONDITION.TITLE',
    description: 'AGENT_BOTS.BUILDER.NODES.CONDITION.DESCRIPTION',
    tint: 'amber',
  },
  delay: {
    inputs: 1,
    outputs: 1,
    icon: 'i-lucide-clock-3',
    group: 'logic',
    title: 'AGENT_BOTS.BUILDER.NODES.DELAY.TITLE',
    description: 'AGENT_BOTS.BUILDER.NODES.DELAY.DESCRIPTION',
    tint: 'sky',
  },
  note: {
    inputs: 1,
    outputs: 1,
    icon: 'i-lucide-sticky-note',
    group: 'logic',
    title: 'AGENT_BOTS.BUILDER.NODES.NOTE.TITLE',
    description: 'AGENT_BOTS.BUILDER.NODES.NOTE.DESCRIPTION',
    tint: 'slate',
  },
  add_label: {
    inputs: 1,
    outputs: 1,
    icon: 'i-lucide-tag',
    group: 'actions',
    title: 'AGENT_BOTS.BUILDER.STEPS.ADD_LABEL',
    description: 'AGENT_BOTS.BUILDER.STEP_HELP.ADD_LABEL',
    tint: 'emerald',
  },
  remove_label: {
    inputs: 1,
    outputs: 1,
    icon: 'i-lucide-tag-x',
    group: 'actions',
    title: 'AGENT_BOTS.BUILDER.STEPS.REMOVE_LABEL',
    description: 'AGENT_BOTS.BUILDER.STEP_HELP.REMOVE_LABEL',
    tint: 'rose',
  },
  assign_team: {
    inputs: 1,
    outputs: 1,
    icon: 'i-lucide-users',
    group: 'routing',
    title: 'AGENT_BOTS.BUILDER.STEPS.ASSIGN_TEAM',
    description: 'AGENT_BOTS.BUILDER.STEP_HELP.ASSIGN_TEAM',
    tint: 'teal',
  },
  assign_agent: {
    inputs: 1,
    outputs: 1,
    icon: 'i-lucide-user-round',
    group: 'routing',
    title: 'AGENT_BOTS.BUILDER.STEPS.ASSIGN_AGENT',
    description: 'AGENT_BOTS.BUILDER.STEP_HELP.ASSIGN_AGENT',
    tint: 'cyan',
  },
  change_status: {
    inputs: 1,
    outputs: 1,
    icon: 'i-lucide-toggle-right',
    group: 'actions',
    title: 'AGENT_BOTS.BUILDER.STEPS.CHANGE_STATUS',
    description: 'AGENT_BOTS.BUILDER.STEP_HELP.CHANGE_STATUS',
    tint: 'indigo',
  },
  handoff: {
    inputs: 1,
    outputs: 1,
    icon: 'i-lucide-arrow-right-left',
    group: 'routing',
    title: 'AGENT_BOTS.BUILDER.STEPS.HANDOFF',
    description: 'AGENT_BOTS.BUILDER.STEP_HELP.HANDOFF',
    tint: 'orange',
  },
  webhook: {
    inputs: 1,
    outputs: 1,
    icon: 'i-lucide-globe',
    group: 'integrations',
    title: 'AGENT_BOTS.TYPES.WEBHOOK',
    description: 'AGENT_BOTS.WEBHOOK.DESCRIPTION',
    tint: 'blue',
  },
};

const createPorts = (kind, count) =>
  Array.from({ length: count }).reduce((acc, _value, index) => {
    acc[`${kind}_${index + 1}`] = { connections: [] };
    return acc;
  }, {});

const normalizeKeywords = keywords => {
  if (typeof keywords === 'string') {
    return keywords
      .split(',')
      .map(keyword => keyword.trim())
      .filter(Boolean);
  }

  return Array.isArray(keywords)
    ? keywords.map(keyword => `${keyword}`.trim()).filter(Boolean)
    : [];
};

const normalizeMenuOptions = options =>
  Array.isArray(options)
    ? options.map((option, index) => ({
        id: option?.id || createId(`option_${index + 1}`),
        label: option?.label || '',
        value: option?.value || '',
      }))
    : [];

export const getOutputCount = (type, data = {}) => {
  if (type === 'menu') {
    return Math.max((data.options || []).length, 1);
  }

  if (type === 'condition') {
    return 2;
  }

  return 1;
};

export const createDefaultNodeData = type => {
  switch (type) {
    case 'trigger':
      return {
        event: 'all_messages',
        keywords: [],
      };
    case 'message':
    case 'note':
      return { body: '' };
    case 'menu':
      return {
        body: '',
        invalid_reply_message: '',
        options: [
          { id: createId('option'), label: '', value: '' },
          { id: createId('option'), label: '', value: '' },
        ],
      };
    case 'condition':
      return {
        field: 'message_text',
        operator: 'contains',
        value: '',
        label_ids: [],
      };
    case 'delay':
      return { seconds: 5 };
    case 'add_label':
    case 'remove_label':
      return { label_ids: [] };
    case 'assign_team':
      return { team_id: '' };
    case 'assign_agent':
      return { agent_id: '' };
    case 'change_status':
      return { status: 'open' };
    case 'handoff':
      return {
        team_id: '',
        agent_id: '',
        status: 'open',
        note: '',
        disable_bot: true,
      };
    case 'webhook':
      return {
        method: 'POST',
        url: '',
      };
    default:
      return {};
  }
};

export const buildNodeRecord = ({
  id = createId('node'),
  type,
  x = 120,
  y = 120,
  data = {},
}) => {
  const inputs = FLOW_NODE_DEFINITIONS[type]?.inputs ?? 1;
  const mergedData = {
    ...createDefaultNodeData(type),
    ...data,
  };

  if (type === 'trigger') {
    mergedData.keywords = normalizeKeywords(mergedData.keywords);
  }

  if (type === 'menu') {
    mergedData.options = normalizeMenuOptions(mergedData.options);
  }

  if (type === 'condition') {
    mergedData.label_ids = Array.isArray(mergedData.label_ids)
      ? mergedData.label_ids.map(value => `${value}`)
      : [];
  }

  if (type === 'add_label' || type === 'remove_label') {
    mergedData.label_ids = Array.isArray(mergedData.label_ids)
      ? mergedData.label_ids.map(value => `${value}`)
      : [];
  }

  return {
    id: `${id}`,
    name: type,
    data: mergedData,
    class: type,
    html: '',
    inputs: createPorts('input', inputs),
    outputs: createPorts('output', getOutputCount(type, mergedData)),
    pos_x: Number(x) || 0,
    pos_y: Number(y) || 0,
  };
};

const connectNodes = (flowData, sourceId, targetId, outputKey = 'output_1') => {
  const sourceNode = flowData[sourceId];
  const targetNode = flowData[targetId];
  if (!sourceNode || !targetNode) return;

  sourceNode.outputs[outputKey] ||= { connections: [] };
  targetNode.inputs.input_1 ||= { connections: [] };

  const alreadyConnected = sourceNode.outputs[outputKey].connections.some(
    connection =>
      connection.node === `${targetId}` && connection.output === 'input_1'
  );

  if (alreadyConnected) return;

  sourceNode.outputs[outputKey].connections.push({
    node: `${targetId}`,
    output: 'input_1',
  });

  targetNode.inputs.input_1.connections.push({
    node: `${sourceId}`,
    input: outputKey,
  });
};

const createDefaultFlowData = () => {
  const triggerNode = buildNodeRecord({
    id: DEFAULT_TRIGGER_ID,
    type: 'trigger',
    x: 140,
    y: 200,
  });

  return {
    [DEFAULT_TRIGGER_ID]: triggerNode,
  };
};

export const createDefaultFlowConfig = () => ({
  version: FLOW_VERSION,
  flow: {
    drawflow: {
      [FLOW_MODULE]: {
        data: createDefaultFlowData(),
      },
    },
  },
});

const isGraphConfig = config =>
  Boolean(
    config?.flow?.drawflow?.[FLOW_MODULE]?.data ||
      config?.drawflow?.[FLOW_MODULE]?.data
  );

const isLinearConfig = config => Boolean(config?.steps || config?.trigger);

const convertLegacyConfig = config => {
  const flowData = createDefaultFlowData();
  const triggerNode = flowData[DEFAULT_TRIGGER_ID];
  triggerNode.data = {
    ...triggerNode.data,
    event: config?.trigger?.event || 'all_messages',
    keywords: normalizeKeywords(config?.trigger?.keywords),
  };

  const steps = Array.isArray(config?.steps) ? config.steps : [];
  const stepIds = [];

  steps.forEach((step, index) => {
    const type = step?.type;
    if (!type) return;

    const nodeId = step.id || createId(`legacy_${type}`);
    stepIds.push(nodeId);
    flowData[nodeId] = buildNodeRecord({
      id: nodeId,
      type,
      x: 500 + index * 320,
      y: 120 + (index % 3) * 220,
      data: step,
    });
  });

  if (stepIds.length) {
    connectNodes(flowData, DEFAULT_TRIGGER_ID, stepIds[0]);
  }

  steps.forEach((step, index) => {
    const sourceId = stepIds[index];
    const nextId = stepIds[index + 1];
    if (!sourceId) return;

    if (step.type === 'menu') {
      const options = normalizeMenuOptions(step.options);
      flowData[sourceId].data.options = options;
      flowData[sourceId].outputs = createPorts(
        'output',
        Math.max(options.length, 1)
      );

      options.forEach((option, optionIndex) => {
        const targetId = step.options?.[optionIndex]?.target_step_id || nextId;
        if (targetId) {
          connectNodes(
            flowData,
            sourceId,
            targetId,
            `output_${optionIndex + 1}`
          );
        }
      });
    } else if (nextId) {
      connectNodes(flowData, sourceId, nextId);
    }
  });

  return {
    version: FLOW_VERSION,
    flow: {
      drawflow: {
        [FLOW_MODULE]: {
          data: flowData,
        },
      },
    },
  };
};

const normalizeGraphConfig = config => {
  const source = config.flow || config;
  const flowData = source?.drawflow?.[FLOW_MODULE]?.data || {};
  const normalizedData = Object.entries(flowData).reduce(
    (acc, [rawId, rawNode]) => {
      const type = rawNode?.name || rawNode?.class;
      if (!type) return acc;

      const nodeId = rawNode.id || rawId;
      acc[nodeId] = buildNodeRecord({
        id: nodeId,
        type,
        x: rawNode.pos_x,
        y: rawNode.pos_y,
        data: rawNode.data,
      });

      const existingOutputs = rawNode.outputs || {};
      Object.entries(existingOutputs).forEach(([key, output]) => {
        acc[nodeId].outputs[key] ||= { connections: [] };
        acc[nodeId].outputs[key].connections = Array.isArray(
          output?.connections
        )
          ? output.connections.map(connection => ({
              node: `${connection.node}`,
              output: connection.output || 'input_1',
            }))
          : [];
      });

      const existingInputs = rawNode.inputs || {};
      Object.entries(existingInputs).forEach(([key, input]) => {
        acc[nodeId].inputs[key] ||= { connections: [] };
        acc[nodeId].inputs[key].connections = Array.isArray(input?.connections)
          ? input.connections.map(connection => ({
              node: `${connection.node}`,
              input: connection.input || 'output_1',
            }))
          : [];
      });

      return acc;
    },
    {}
  );

  if (!Object.keys(normalizedData).length) {
    return createDefaultFlowConfig();
  }

  return {
    version: config.version || FLOW_VERSION,
    flow: {
      drawflow: {
        [FLOW_MODULE]: {
          data: normalizedData,
        },
      },
    },
  };
};

export const normalizeFlowConfig = config => {
  if (!config) return createDefaultFlowConfig();
  if (isGraphConfig(config)) return normalizeGraphConfig(config);
  if (isLinearConfig(config)) return convertLegacyConfig(config);
  return createDefaultFlowConfig();
};

export const cloneFlowConfig = config =>
  JSON.parse(JSON.stringify(normalizeFlowConfig(config)));

export const getFlowData = config =>
  normalizeFlowConfig(config).flow.drawflow[FLOW_MODULE].data;

export const getTriggerSummary = config => {
  const flowData = getFlowData(config);
  const triggerNode = Object.values(flowData).find(
    node => node.name === 'trigger'
  );
  const event = triggerNode?.data?.event || 'all_messages';
  const keywords = normalizeKeywords(triggerNode?.data?.keywords);

  return { event, keywords };
};

export const countConnections = config =>
  Object.values(getFlowData(config)).reduce((total, node) => {
    return (
      total +
      Object.values(node.outputs || {}).reduce((count, output) => {
        return count + (output.connections?.length || 0);
      }, 0)
    );
  }, 0);
