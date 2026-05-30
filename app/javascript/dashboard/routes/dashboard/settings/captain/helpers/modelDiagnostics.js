const reasonDetails = reason => reason.details || {};

const selectedDiagnostics = feature => feature?.selected_diagnostics || {};
const diagnosticReasons = feature => selectedDiagnostics(feature).reasons || [];

const localizedDiagnosticReason = (reason, t) => {
  switch (reason.code) {
    case 'model_not_found':
      return t(
        'CAPTAIN_SETTINGS.MODEL_CONFIG.DIAGNOSTICS.REASONS.MODEL_NOT_FOUND',
        reasonDetails(reason)
      );
    case 'provider_not_configured':
      return t(
        'CAPTAIN_SETTINGS.MODEL_CONFIG.DIAGNOSTICS.REASONS.PROVIDER_NOT_CONFIGURED',
        reasonDetails(reason)
      );
    case 'direct_provider_disabled':
      return t(
        'CAPTAIN_SETTINGS.MODEL_CONFIG.DIAGNOSTICS.REASONS.DIRECT_PROVIDER_DISABLED',
        reasonDetails(reason)
      );
    case 'voice_only_provider':
      return t(
        'CAPTAIN_SETTINGS.MODEL_CONFIG.DIAGNOSTICS.REASONS.VOICE_ONLY_PROVIDER',
        reasonDetails(reason)
      );
    case 'structured_output_unsupported':
      return t(
        'CAPTAIN_SETTINGS.MODEL_CONFIG.DIAGNOSTICS.REASONS.STRUCTURED_OUTPUT_UNSUPPORTED',
        reasonDetails(reason)
      );
    case 'tool_calling_unsupported':
      return t(
        'CAPTAIN_SETTINGS.MODEL_CONFIG.DIAGNOSTICS.REASONS.TOOL_CALLING_UNSUPPORTED',
        reasonDetails(reason)
      );
    case 'missing_capability':
      return t(
        'CAPTAIN_SETTINGS.MODEL_CONFIG.DIAGNOSTICS.REASONS.MISSING_CAPABILITY',
        reasonDetails(reason)
      );
    case 'unsupported_type':
      return t(
        'CAPTAIN_SETTINGS.MODEL_CONFIG.DIAGNOSTICS.REASONS.UNSUPPORTED_TYPE',
        reasonDetails(reason)
      );
    case 'embedding_dimension_mismatch':
      return t(
        'CAPTAIN_SETTINGS.MODEL_CONFIG.DIAGNOSTICS.REASONS.EMBEDDING_DIMENSION_MISMATCH',
        reasonDetails(reason)
      );
    case 'context_too_small':
      return t(
        'CAPTAIN_SETTINGS.MODEL_CONFIG.DIAGNOSTICS.REASONS.CONTEXT_TOO_SMALL',
        reasonDetails(reason)
      );
    case 'zdr_required_unsupported':
      return t(
        'CAPTAIN_SETTINGS.MODEL_CONFIG.DIAGNOSTICS.REASONS.ZDR_REQUIRED_UNSUPPORTED',
        reasonDetails(reason)
      );
    case 'privacy_profile_invalid':
      return t(
        'CAPTAIN_SETTINGS.MODEL_CONFIG.DIAGNOSTICS.REASONS.PRIVACY_PROFILE_INVALID',
        reasonDetails(reason)
      );
    case 'capability_diagnostics_failed':
      return t(
        'CAPTAIN_SETTINGS.MODEL_CONFIG.DIAGNOSTICS.REASONS.CAPABILITY_DIAGNOSTICS_FAILED',
        reasonDetails(reason)
      );
    default:
      return reason.message || reason.code;
  }
};

export const hasSelectedModelDiagnostics = feature =>
  selectedDiagnostics(feature).allowed === false &&
  diagnosticReasons(feature).length > 0;

export const selectedModelIdForDiagnostics = feature =>
  feature?.selected || feature?.default || '';

export const localizedDiagnosticReasonsFromDiagnostics = (diagnostics, t) =>
  (diagnostics?.reasons || [])
    .map(reason => localizedDiagnosticReason(reason, t))
    .filter(Boolean);

export const localizedDiagnosticReasons = (feature, t) =>
  localizedDiagnosticReasonsFromDiagnostics(selectedDiagnostics(feature), t);

export const isNativeAudioTranscriptionModel = model =>
  model?.type === 'transcription';

export const shouldShowAudioTranscriptionPrompt = model =>
  !isNativeAudioTranscriptionModel(model);
