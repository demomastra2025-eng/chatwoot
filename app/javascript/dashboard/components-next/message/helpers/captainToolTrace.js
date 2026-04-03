export const buildCaptainToolTraceMessages = additionalAttributes => {
  const toolSteps = additionalAttributes?.captainTrace?.toolSteps;

  if (!Array.isArray(toolSteps) || toolSteps.length === 0) {
    return [];
  }

  return toolSteps
    .filter(step => step?.content)
    .map((step, index) => ({
      id: step.id || `${step.toolName || 'tool'}-${index}`,
      message: {
        content: step.content,
      },
    }));
};
