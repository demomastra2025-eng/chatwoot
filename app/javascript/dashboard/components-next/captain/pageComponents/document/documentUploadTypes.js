export const UPLOADABLE_FILE_EXTENSIONS = [
  'pdf',
  'docx',
  'doc',
  'odt',
  'rtf',
  'xlsx',
  'xls',
  'html',
  'htm',
  'txt',
  'text',
  'md',
  'markdown',
  'csv',
  'json',
  'xml',
  'yaml',
  'yml',
  'jpg',
  'jpeg',
  'png',
  'webp',
  'gif',
  'heic',
  'heif',
  'tiff',
  'tif',
  'bmp',
];

export const UPLOAD_FILE_ACCEPT = UPLOADABLE_FILE_EXTENSIONS.map(
  extension => `.${extension}`
).join(',');
