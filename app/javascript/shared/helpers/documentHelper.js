/**
 * Document Helper - utilities for document display and formatting
 */

// Constants for document processing
const PDF_PREFIX = 'PDF:';
const FILE_PREFIX = 'FILE:';
const TIMESTAMPED_FILE_PATTERN = /_\d{14}(?=\.[^.]+$|$)/;
const SUPPORTED_REMOTE_DOCUMENT_EXTENSIONS = [
  'pdf',
  'docx',
  'doc',
  'odt',
  'rtf',
  'xlsx',
  'xls',
];

const extractExtensionFromPath = path => {
  const fileName = path.split('/').pop() || '';
  if (!fileName.includes('.')) return '';

  return fileName.split('.').pop()?.toLowerCase() || '';
};

const extractDocumentExtension = value => {
  if (!value) return '';
  if (value.startsWith(PDF_PREFIX)) return 'pdf';

  try {
    return extractExtensionFromPath(new URL(value).pathname);
  } catch {
    return extractExtensionFromPath(value.split('?')[0].split('#')[0]);
  }
};

/**
 * Checks if a document is a PDF based on its external link
 * @param {string} externalLink - The external link string
 * @returns {boolean} True if the document is a PDF
 */
export const isPdfDocument = externalLink => {
  if (!externalLink) return false;
  return extractDocumentExtension(externalLink) === 'pdf';
};

export const isSupportedRemoteDocument = externalLink =>
  SUPPORTED_REMOTE_DOCUMENT_EXTENSIONS.includes(
    extractDocumentExtension(externalLink)
  );

export const documentLinkIcon = externalLink => {
  if (isPdfDocument(externalLink)) return 'i-ph-file-pdf';
  if (isSupportedRemoteDocument(externalLink)) return 'i-ph-file-text';

  return 'i-ph-link-simple';
};

/**
 * Formats the display link for documents
 * For PDF documents: removes 'PDF:' prefix and timestamp suffix
 * For regular URLs: returns as-is
 *
 * @param {string} externalLink - The external link string
 * @returns {string} Formatted display link
 */
export const formatDocumentLink = externalLink => {
  if (!externalLink) return '';

  if (externalLink.startsWith(PDF_PREFIX)) {
    // Remove 'PDF:' prefix
    const fullName = externalLink.substring(PDF_PREFIX.length).trimStart();
    // Remove timestamp suffix if present before the extension.
    return fullName.replace(TIMESTAMPED_FILE_PATTERN, '');
  }

  if (externalLink.startsWith(FILE_PREFIX)) {
    const fullName = externalLink.substring(FILE_PREFIX.length).trimStart();
    return fullName.replace(TIMESTAMPED_FILE_PATTERN, '');
  }

  return externalLink;
};
