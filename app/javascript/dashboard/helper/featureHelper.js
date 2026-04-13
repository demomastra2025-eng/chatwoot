export function getHelpUrlForFeature(featureName) {
  return window?.chatwootConfig?.helpUrls?.[featureName] || '';
}
