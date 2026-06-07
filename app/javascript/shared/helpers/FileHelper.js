import { getAllowedFileTypesByChannel } from '@chatwoot/utils';
import { getMaxUploadSizeByChannel } from '@chatwoot/utils';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import {
  ALLOWED_FILE_TYPES,
  BUSINESS_CERTIFICATE_FILE_TYPES,
} from 'shared/constants/messages';

export const DEFAULT_MAXIMUM_FILE_UPLOAD_SIZE = 40;
export const WHATSAPP_VIDEO_UPLOAD_SIZE = 70;
export const WHATSAPP_DOCUMENT_UPLOAD_SIZE = 70;

export const formatBytes = (bytes, decimals = 2) => {
  if (bytes === 0) return '0 Bytes';

  const k = 1024;
  const dm = decimals < 0 ? 0 : decimals;
  const sizes = ['Bytes', 'KB', 'MB', 'GB', 'TB', 'PB', 'EB', 'ZB', 'YB'];

  const i = Math.floor(Math.log(bytes) / Math.log(k));

  return parseFloat((bytes / k ** i).toFixed(dm)) + ' ' + sizes[i];
};

export const fileSizeInMegaBytes = bytes => {
  return bytes / (1024 * 1024);
};

export const checkFileSizeLimit = (file, maximumUploadLimit) => {
  const fileSize = file?.file?.size || file?.size;
  const fileSizeInMB = fileSizeInMegaBytes(fileSize);
  return fileSizeInMB <= maximumUploadLimit;
};

export const resolveMaximumFileUploadSize = value => {
  const parsedValue = Number(value);

  if (!Number.isFinite(parsedValue) || parsedValue <= 0) {
    return DEFAULT_MAXIMUM_FILE_UPLOAD_SIZE;
  }

  return parsedValue;
};

export const resolveConversationUploadLimit = ({
  channelType,
  medium,
  mime,
  installationLimit,
  isPrivateNote = false,
}) => {
  if (isPrivateNote) {
    return installationLimit;
  }

  if (!channelType || channelType === INBOX_TYPES.WEB) {
    return installationLimit;
  }

  const normalizedChannelType = channelType.toLowerCase();
  const normalizedMedium = (medium || '').toLowerCase();
  const normalizedMime = (mime || '').toLowerCase();

  if (
    (normalizedChannelType === 'channel::whatsapp' ||
      normalizedChannelType === 'channel::whatsappweb' ||
      normalizedMedium === 'whatsapp') &&
    normalizedMime.startsWith('video/')
  ) {
    return WHATSAPP_VIDEO_UPLOAD_SIZE;
  }

  if (
    (normalizedChannelType === 'channel::whatsapp' ||
      normalizedChannelType === 'channel::whatsappweb' ||
      normalizedMedium === 'whatsapp') &&
    (normalizedMime.startsWith('application/') ||
      normalizedMime.startsWith('text/'))
  ) {
    return WHATSAPP_DOCUMENT_UPLOAD_SIZE;
  }

  const channelLimit = getMaxUploadSizeByChannel({
    channelType,
    medium,
    mime,
  });

  if (channelLimit === DEFAULT_MAXIMUM_FILE_UPLOAD_SIZE) {
    return installationLimit;
  }

  return Math.min(channelLimit, installationLimit);
};

const normalizeAcceptList = fileTypes =>
  (fileTypes || '')
    .split(',')
    .map(type => type.trim())
    .filter(Boolean);

export const withBusinessCertificateFileTypes = fileTypes => {
  const allowedTypes = normalizeAcceptList(fileTypes);

  if (
    !allowedTypes.includes('application/xml') &&
    !allowedTypes.includes('text/xml')
  ) {
    return allowedTypes.join(', ');
  }

  normalizeAcceptList(BUSINESS_CERTIFICATE_FILE_TYPES).forEach(type => {
    if (!allowedTypes.includes(type)) {
      allowedTypes.push(type);
    }
  });

  return allowedTypes.join(', ');
};

const BUSINESS_CERTIFICATE_EXTENSIONS = new Set(['.p12', '.pfx']);
const BUSINESS_CERTIFICATE_CONTENT_TYPES = new Set([
  'application/pkcs12',
  'application/x-pkcs12',
  'application/octet-stream',
]);

/**
 * Validates if a file type is allowed for a specific channel
 * @param {File} file - The file to validate
 * @param {Object} options - Validation options
 * @param {string} options.channelType - The channel type
 * @param {string} options.medium - The channel medium
 * @param {string} options.conversationType - The conversation type (for Instagram DM detection)
 * @param {boolean} options.isInstagramChannel - Whether it's an Instagram channel
 * @param {boolean} options.isOnPrivateNote - Whether composing a private note (uses broader file type list)
 * @returns {boolean} - True if file type is allowed, false otherwise
 */
export const isFileTypeAllowedForChannel = (file, options = {}) => {
  const uploadFile = file?.file || file;
  if (!uploadFile || uploadFile.size === 0) return false;

  const {
    channelType: originalChannelType,
    medium,
    conversationType,
    isInstagramChannel,
    isOnPrivateNote,
  } = options;
  const isInstagramConversation =
    isInstagramChannel || conversationType === 'instagram_direct_message';

  // Use broader file types for private notes (matches file picker behavior)
  const allowedFileTypes = isOnPrivateNote
    ? ALLOWED_FILE_TYPES
    : withBusinessCertificateFileTypes(
        getAllowedFileTypesByChannel({
          channelType: isInstagramConversation
            ? INBOX_TYPES.INSTAGRAM
            : originalChannelType,
          medium,
        })
      );

  // Convert to array and validate
  const allowedTypesArray = normalizeAcceptList(allowedFileTypes).map(type =>
    type.toLowerCase()
  );
  const fileExtension = `.${uploadFile.name.split('.').pop()}`.toLowerCase();
  const fileType = (uploadFile.type || '').toLowerCase();
  const isBusinessCertificateExtension =
    BUSINESS_CERTIFICATE_EXTENSIONS.has(fileExtension);
  const isBusinessCertificateContentType =
    BUSINESS_CERTIFICATE_CONTENT_TYPES.has(fileType);
  const isBusinessCertificateAllowed = allowedTypesArray.some(
    allowedType =>
      BUSINESS_CERTIFICATE_EXTENSIONS.has(allowedType) ||
      BUSINESS_CERTIFICATE_CONTENT_TYPES.has(allowedType)
  );

  if (isBusinessCertificateExtension || isBusinessCertificateContentType) {
    return (
      isBusinessCertificateAllowed &&
      isBusinessCertificateExtension &&
      (fileType === '' || isBusinessCertificateContentType)
    );
  }

  return allowedTypesArray.some(allowedType => {
    // Check for exact file extension match
    if (allowedType === fileExtension) return true;

    // Check for wildcard MIME type (e.g., image/*)
    if (allowedType.endsWith('/*')) {
      const prefix = allowedType.slice(0, -2); // Remove '/*'
      return fileType.startsWith(prefix + '/');
    }

    // Check for exact MIME type match
    return allowedType === fileType;
  });
};
